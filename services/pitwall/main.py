"""Pit wall: a small web app that shows one replay live.

Serves one page and a JSON API:
  GET  /api/state?run_id=...      timing tower, moments, calls and race clock
  GET  /api/latest                the latest run_id in raw_events, if any
  GET  /api/cars                  one photo per team, with its credit and what Gemini read
  POST /api/start                 runs the replayer job with a new run_id
  POST /api/queries/start         starts both continuous queries
  POST /api/queries/stop          cancels the continuous queries it started

The browser holds the run_id and the continuous query job IDs, so the server
keeps no state between requests. The continuous queries start only after the
replay has written its first events: a continuous query started on an idle
table fails with "Invalid timestamp bounds".
"""

import functools
import json
import logging
import os
import pathlib
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta

import google.auth
from flask import Flask, jsonify, request, send_from_directory
from google.api_core.exceptions import GoogleAPIError
from google.auth.transport.requests import AuthorizedSession
from google.cloud import bigquery

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
logger = logging.getLogger(__name__)

PROJECT_ID = os.environ["PROJECT_ID"]
REGION = os.environ["REGION"]
LOCATION = os.environ["BQ_LOCATION"]
REPLAYER_JOB = os.environ["REPLAYER_JOB"]
CQ_SERVICE_ACCOUNT = os.environ["CQ_SERVICE_ACCOUNT"]
REPLAY_WINDOW_END = os.environ["REPLAY_WINDOW_END"]
REPLAY_SPEED = os.environ["REPLAY_SPEED"]
REPLAY_WINDOW_START = os.environ["REPLAY_WINDOW_START"]
DATA_BUCKET = os.environ["DATA_BUCKET"]
OPENF1_SESSION_KEY = os.environ["OPENF1_SESSION_KEY"]
RACE_NAME = os.environ["RACE_NAME"]
CONTINUOUS_QUERIES = {
    "moments-fast": os.environ["MOMENTS_FAST_SQL"],
    "moments-windowed": os.environ["MOMENTS_WINDOWED_SQL"],
}

_credentials, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
session = AuthorizedSession(_credentials)
bq = bigquery.Client(project=PROJECT_ID)
app = Flask(__name__, static_folder="static")
# The four state queries run side by side, so one poll takes as long as the
# slowest query instead of all four in a row.
pool = ThreadPoolExecutor(max_workers=8)


def run_query(sql: str, run_id: str) -> list[dict]:
    job = bq.query(
        sql,
        job_config=bigquery.QueryJobConfig(
            query_parameters=[bigquery.ScalarQueryParameter("run_id", "STRING", run_id)]
        ),
    )
    return [dict(row) for row in job.result()]


TIMING_SQL = """
WITH ev AS (
  SELECT event_type, event_ts, driver_number, payload
  FROM `{project}.raw.raw_events`
  WHERE run_id = @run_id
    AND event_type IN ('drivers', 'position', 'intervals', 'stints', 'laps')
),
drivers AS (
  SELECT driver_number,
    ANY_VALUE(JSON_VALUE(payload, '$.name_acronym')) AS code,
    ANY_VALUE(JSON_VALUE(payload, '$.full_name')) AS full_name,
    ANY_VALUE(JSON_VALUE(payload, '$.team_name')) AS team_name,
    ANY_VALUE(JSON_VALUE(payload, '$.team_colour')) AS colour
  FROM ev WHERE event_type = 'drivers' GROUP BY driver_number
),
latest AS (
  SELECT event_type, driver_number,
    ARRAY_AGG(payload ORDER BY event_ts DESC LIMIT 1)[OFFSET(0)] AS payload
  FROM ev WHERE event_type IN ('position', 'intervals', 'stints', 'laps')
  GROUP BY event_type, driver_number
)
SELECT
  d.driver_number, d.code, d.full_name, d.team_name, d.colour,
  SAFE.INT64(p.payload.position) AS position,
  JSON_VALUE(i.payload, '$.gap_to_leader') AS gap_to_leader,
  JSON_VALUE(i.payload, '$.interval') AS interval_ahead,
  JSON_VALUE(s.payload, '$.compound') AS compound,
  SAFE.INT64(l.payload.lap_number) - SAFE.INT64(s.payload.lap_start)
    + SAFE.INT64(s.payload.tyre_age_at_start) AS tyre_age,
  SAFE.INT64(l.payload.lap_number) AS lap,
  SAFE.FLOAT64(l.payload.lap_duration) AS last_lap
FROM drivers AS d
LEFT JOIN latest AS p ON p.driver_number = d.driver_number AND p.event_type = 'position'
LEFT JOIN latest AS i ON i.driver_number = d.driver_number AND i.event_type = 'intervals'
LEFT JOIN latest AS s ON s.driver_number = d.driver_number AND s.event_type = 'stints'
LEFT JOIN latest AS l ON l.driver_number = d.driver_number AND l.event_type = 'laps'
ORDER BY position
"""

MOMENTS_SQL = """
WITH laps AS (
  SELECT event_ts, SAFE.INT64(payload.lap_number) AS lap_number
  FROM `{project}.raw.raw_events`
  WHERE run_id = @run_id AND event_type = 'laps'
),
dedup AS (
  SELECT moment, driver_number, lap, event_ts, detail, publish_time
  FROM `{project}.serving.moments`
  WHERE run_id = @run_id
  QUALIFY ROW_NUMBER() OVER (PARTITION BY moment, driver_number, event_ts ORDER BY publish_time) = 1
  ORDER BY event_ts DESC
  LIMIT 60
)
SELECT
  m.moment,
  m.driver_number,
  COALESCE(
    m.lap,
    (SELECT MAX(l.lap_number) FROM laps AS l WHERE l.event_ts <= m.event_ts)
  ) AS lap,
  m.event_ts,
  m.detail,
  m.publish_time
FROM dedup AS m
ORDER BY m.event_ts DESC
"""

CALLS_SQL = """
SELECT moment, driver_number, lap, event_ts, status, call_text, error, latency_ms, created_at
FROM `{project}.serving.calls`
WHERE run_id = @run_id
ORDER BY event_ts DESC
LIMIT 25
"""

CLOCK_SQL = """
SELECT COUNT(*) AS events, MAX(event_ts) AS race_time, MAX(publish_time) AS last_publish
FROM `{project}.raw.raw_events`
WHERE run_id = @run_id
"""

LATEST_RUN_SQL = """
SELECT run_id
FROM `{project}.raw.raw_events`
WHERE event_type = 'drivers'
ORDER BY publish_time DESC
LIMIT 1
"""

# One row per team: a signed read URL for the photo (OBJ.GET_ACCESS_URL signs
# it for 6 hours), the credit stored with the file, and Gemini's reading.
CARS_SQL = """
SELECT
  p.team,
  JSON_VALUE(OBJ.GET_ACCESS_URL(p.ref, 'r'), '$.access_urls.read_url') AS photo_url,
  (SELECT value FROM UNNEST(p.metadata) WHERE name = 'author') AS author,
  (SELECT value FROM UNNEST(p.metadata) WHERE name = 'license') AS license,
  (SELECT value FROM UNNEST(p.metadata) WHERE name = 'license_url') AS license_url,
  (SELECT value FROM UNNEST(p.metadata) WHERE name = 'source') AS source,
  c.livery_colours,
  c.sponsors
FROM (
  SELECT uri, ref, metadata,
    (SELECT value FROM UNNEST(metadata) WHERE name = 'team') AS team
  FROM `{project}.raw.car_photos`
) AS p
LEFT JOIN `{project}.serving.cars` AS c USING (uri)
ORDER BY p.team
"""
# Refresh well before the signed URLs expire.
CARS_TTL_SECONDS = 3600
_cars_cache: dict = {"at": None, "rows": []}
_cars_lock = threading.Lock()


def _jsonable(rows: list[dict]) -> list[dict]:
    return [
        {k: (v.isoformat() if hasattr(v, "isoformat") else v) for k, v in row.items()}
        for row in rows
    ]


def _race_time(value: str) -> datetime:
    return datetime.fromisoformat(value[:19])


@functools.cache
def _window_laps() -> dict:
    """Return the first and last lap of the replay window, from laps.json.

    first: the lap in progress at the window start.
    last: the last lap completed by the window end, which is what the timing
    tower shows when the replay ends (a lap publishes when it ends).
    """
    url = (
        f"https://storage.googleapis.com/storage/v1/b/{DATA_BUCKET}/o/"
        f"openf1%2F{OPENF1_SESSION_KEY}%2Flaps.json?alt=media"
    )
    response = session.get(url, timeout=30)
    response.raise_for_status()
    laps = [lap for lap in response.json() if lap.get("date_start")]
    start, end = _race_time(REPLAY_WINDOW_START), _race_time(REPLAY_WINDOW_END)
    first = max(
        (lap["lap_number"] for lap in laps if _race_time(lap["date_start"]) <= start),
        default=None,
    )
    last = max(
        (
            lap["lap_number"]
            for lap in laps
            if lap.get("lap_duration")
            and _race_time(lap["date_start"]) + timedelta(seconds=lap["lap_duration"]) <= end
        ),
        default=None,
    )
    return {"first": first, "last": last}


def _window_laps_or_empty() -> dict:
    # The page still works without lap labels, so a read failure is logged, not raised.
    try:
        return _window_laps()
    except (OSError, ValueError, KeyError) as exc:
        logger.warning("could not read the window laps: %s", exc)
        return {}


def _local_overlay() -> dict:
    path = pathlib.Path(app.static_folder) / "local" / "overlay.json"
    if path.is_file():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            logger.warning("could not read local overlay: %s", exc)
    return {}


@app.get("/")
def index():
    return send_from_directory(app.static_folder, "index.html")


@app.get("/api/latest")
def latest():
    job = bq.query(LATEST_RUN_SQL.format(project=PROJECT_ID))
    rows = [dict(row) for row in job.result()]
    return jsonify(
        {
            "run_id": rows[0]["run_id"] if rows else None,
            "window_end": REPLAY_WINDOW_END,
            "replay_speed": REPLAY_SPEED,
            "race_name": RACE_NAME,
            "window_laps": _window_laps_or_empty(),
            "overlay": _local_overlay(),
        }
    )


@app.get("/api/cars")
def cars():
    # The page works without photos, so a missing table answers with an empty list.
    with _cars_lock:
        stale = _cars_cache["at"] is None or time.monotonic() - _cars_cache["at"] > CARS_TTL_SECONDS
        if stale:
            try:
                rows = [dict(row) for row in bq.query(CARS_SQL.format(project=PROJECT_ID)).result()]
                _cars_cache.update(at=time.monotonic(), rows=rows)
            except GoogleAPIError as exc:
                logger.warning("could not read the car photos: %s", exc)
                return jsonify({"cars": []})
        return jsonify({"cars": _cars_cache["rows"]})


@app.get("/api/state")
def state():
    run_id = request.args.get("run_id", "")
    if not run_id:
        return jsonify({"error": "run_id is required"}), 400
    queries = {"clock": CLOCK_SQL, "timing": TIMING_SQL, "moments": MOMENTS_SQL, "calls": CALLS_SQL}
    futures = {
        name: pool.submit(run_query, sql.format(project=PROJECT_ID), run_id)
        for name, sql in queries.items()
    }
    result = {name: _jsonable(future.result()) for name, future in futures.items()}
    result["clock"] = result["clock"][0]
    result["window_end"] = REPLAY_WINDOW_END
    return jsonify(result)


@app.post("/api/start")
def start():
    run_id = f"run-{uuid.uuid4().hex[:8]}"
    url = (
        f"https://run.googleapis.com/v2/projects/{PROJECT_ID}/locations/{REGION}"
        f"/jobs/{REPLAYER_JOB}:run"
    )
    body = {"overrides": {"containerOverrides": [{"env": [{"name": "RUN_ID", "value": run_id}]}]}}
    response = session.post(url, json=body, timeout=30)
    if not response.ok:
        logger.error("could not start the replayer: %s", response.text)
        return jsonify({"error": response.text}), 502
    logger.info("started replay %s", run_id)
    return jsonify({"run_id": run_id})


@app.post("/api/queries/start")
def start_queries():
    url = f"https://bigquery.googleapis.com/bigquery/v2/projects/{PROJECT_ID}/jobs"
    job_ids = []
    for name, sql in CONTINUOUS_QUERIES.items():
        body = {
            "jobReference": {"projectId": PROJECT_ID, "location": LOCATION},
            "configuration": {
                "labels": {"pitwall": name},
                "query": {
                    "query": sql,
                    "useLegacySql": False,
                    "continuous": True,
                    "connectionProperties": [
                        {"key": "service_account", "value": CQ_SERVICE_ACCOUNT}
                    ],
                },
            },
        }
        response = session.post(url, json=body, timeout=120)
        if not response.ok:
            logger.error("could not start %s: %s", name, response.text)
            return jsonify({"error": response.text, "started": job_ids}), 502
        job_ids.append(response.json()["jobReference"]["jobId"])
    logger.info("started continuous queries %s", job_ids)
    return jsonify({"job_ids": job_ids})


@app.post("/api/queries/stop")
def stop_queries():
    job_ids = (request.get_json(silent=True) or {}).get("job_ids", [])
    for job_id in job_ids:
        url = (
            f"https://bigquery.googleapis.com/bigquery/v2/projects/{PROJECT_ID}"
            f"/jobs/{job_id}/cancel?location={LOCATION}"
        )
        response = session.post(url, timeout=30)
        if not response.ok:
            logger.error("could not cancel %s: %s", job_id, response.text)
    return jsonify({"cancelled": job_ids})
