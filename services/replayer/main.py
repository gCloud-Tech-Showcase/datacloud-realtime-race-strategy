"""Replay one F1 race from the race-data bucket to Pub/Sub, as if it were live.

Runs as a Cloud Run job. It reads the OpenF1 files that the loader wrote during
apply, publishes the state at the start of the window as one burst, then
publishes the window itself at SPEED times real time. Every message carries
RUN_ID, so repeated replays stay apart in BigQuery.

A record is published at the moment it became known during the race, never
earlier: a lap when it ends, and a stint without its last lap, when the car
leaves the pit lane. Otherwise the strategist could see the future.

Each weather record also carries previous_rainfall, the reading before it,
which the replayer adds. A one-row rule can then spot the change from dry to
wet. A TUMBLE window misses the change when the two readings fall on either
side of a window boundary (seen on 2026-10-25).

Environment:
  PROJECT_ID, TOPIC, BUCKET, SESSION_KEY  where to read and publish
  WINDOW_START, WINDOW_END                race time, ISO 8601 UTC
  SPEED                                   replay speed, default 5
  RUN_ID                                  set by the pit wall, default a new UUID
"""

import json
import logging
import os
import time
import uuid
from datetime import UTC, datetime, timedelta

from google.cloud import pubsub_v1, storage

logger = logging.getLogger(__name__)

WINDOW_STREAMS = ["car_data", "intervals", "race_control", "weather", "pit", "overtakes"]


def parse_ts(value: str) -> datetime:
    parsed = datetime.fromisoformat(value)
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)


def read_stream(bucket: storage.Bucket, session_key: str, stream: str) -> list:
    blob = bucket.blob(f"openf1/{session_key}/{stream}.json")
    return json.loads(blob.download_as_bytes())


def build_events(bucket, session_key, start, end):
    """Return (state_at_start, window) as lists of (known_at, event_type, record)."""
    state, window = [], []

    def place(known_at, event_type, record):
        if known_at < start:
            state.append((known_at, event_type, record))
        elif known_at <= end:
            window.append((known_at, event_type, record))

    for stream in WINDOW_STREAMS:
        records = read_stream(bucket, session_key, stream)
        if stream == "weather":
            records.sort(key=lambda r: r["date"])
            previous = None
            for record in records:
                record["previous_rainfall"] = previous
                previous = record.get("rainfall")
        for record in records:
            place(parse_ts(record["date"]), stream, record)

    # The running order at the window start is the last position of each car.
    latest_position = {}
    for record in read_stream(bucket, session_key, "position"):
        known_at = parse_ts(record["date"])
        if known_at < start:
            latest_position[record["driver_number"]] = (known_at, record)
        elif known_at <= end:
            window.append((known_at, "position", record))
    for known_at, record in latest_position.values():
        state.append((known_at, "position", record))

    # A lap is known when it ends.
    laps = read_stream(bucket, session_key, "laps")
    lap_start = {}
    for record in laps:
        if not record.get("date_start"):
            continue
        lap_start[(record["driver_number"], record["lap_number"])] = parse_ts(record["date_start"])
        if record.get("lap_duration"):
            known_at = parse_ts(record["date_start"]) + timedelta(seconds=record["lap_duration"])
            place(known_at, "laps", record)

    # A stint is known when it starts: the start of the race for the first one,
    # and the moment the car leaves the pit lane for the others. OpenF1 gives a
    # new stint the lap of the pit stop as lap_start, and the car pits partway
    # through that lap, so the start of the lap would show the new tyres about
    # two minutes early (seen on 2026-10-29). Its last lap is known only once
    # the next stint starts, so lap_end is dropped unless that already happened.
    pit_exit = {}
    for record in read_stream(bucket, session_key, "pit"):
        if record.get("lap_number") is not None:
            pit_exit[(record["driver_number"], record["lap_number"])] = parse_ts(
                record["date"]
            ) + timedelta(seconds=record.get("lane_duration") or 0)

    def stint_known_at(driver_number, lap):
        return pit_exit.get((driver_number, lap)) or lap_start.get((driver_number, lap))

    for record in read_stream(bucket, session_key, "stints"):
        known_at = stint_known_at(record["driver_number"], record["lap_start"])
        if known_at is None:
            continue
        stint = dict(record)
        next_start = stint_known_at(record["driver_number"], (record.get("lap_end") or 0) + 1)
        if next_start is None or next_start >= start or known_at >= start:
            stint.pop("lap_end", None)
        place(known_at, "stints", stint)

    # Driver names and team colours, for the pit wall.
    for record in read_stream(bucket, session_key, "drivers"):
        state.append((start - timedelta(seconds=1), "drivers", record))

    state.sort(key=lambda event: event[0])
    window.sort(key=lambda event: event[0])
    return state, window


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    project_id = os.environ["PROJECT_ID"]
    session_key = os.environ["SESSION_KEY"]
    start = parse_ts(os.environ["WINDOW_START"])
    end = parse_ts(os.environ["WINDOW_END"])
    speed = float(os.environ.get("SPEED", "5"))
    run_id = os.environ.get("RUN_ID") or str(uuid.uuid4())

    bucket = storage.Client(project=project_id).bucket(os.environ["BUCKET"])
    state, window = build_events(bucket, session_key, start, end)
    logger.info(
        "run %s: %d state events, %d window events, %sx", run_id, len(state), len(window), speed
    )

    publisher = pubsub_v1.PublisherClient(
        batch_settings=pubsub_v1.types.BatchSettings(max_messages=1000, max_latency=0.05)
    )
    topic = publisher.topic_path(project_id, os.environ["TOPIC"])

    def publish(batch):
        futures = []
        for known_at, event_type, record in batch:
            envelope = {
                "run_id": run_id,
                "event_type": event_type,
                "event_ts": known_at.isoformat(),
                "session_key": int(session_key),
                "driver_number": record.get("driver_number"),
                # A JSON string: the BigQuery subscription rejects a nested
                # object for the JSON column.
                "payload": json.dumps(record),
            }
            futures.append(
                publisher.publish(
                    topic, json.dumps(envelope).encode(), event_type=event_type, run_id=run_id
                )
            )
        for future in futures:
            future.result()

    publish(state)

    wall_start = time.monotonic()
    sent, next_log = 0, 0.0
    while sent < len(window):
        race_now = start + timedelta(seconds=(time.monotonic() - wall_start) * speed)
        due = sent
        while due < len(window) and window[due][0] <= race_now:
            due += 1
        if due > sent:
            publish(window[sent:due])
            sent = due
        elapsed = time.monotonic() - wall_start
        if elapsed >= next_log:
            logger.info("race time %s, %d of %d published", race_now.time(), sent, len(window))
            next_log += 30
        time.sleep(0.2)

    logger.info(
        "run %s done: %d events in %.0fs", run_id, len(state) + sent, time.monotonic() - wall_start
    )


if __name__ == "__main__":
    main()
