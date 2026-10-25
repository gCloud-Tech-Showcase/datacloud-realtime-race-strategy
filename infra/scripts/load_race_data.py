#!/usr/bin/env python3
"""Download one race from the OpenF1 historical API into the race-data bucket.

Runs on the machine that runs `tofu apply` (see race_data.tf), because the
replayer and the rest of the demo never call OpenF1 themselves. F1 data is not
committed to this repository. Each stream lands as one JSON array:

    gs://<bucket>/openf1/<session_key>/<stream>.json

High-rate streams (car_data, intervals, position, race control, weather, pit,
overtakes) are limited to the replay window. Laps, stints and drivers are
downloaded for the whole race, because the replayer builds the pre-race state
from them.

If every file is already in the bucket, the script does nothing, so a re-apply
never calls OpenF1. During a live F1 session, OpenF1 refuses all requests without
an API key, including requests for past races. The script then stops with a
message to run `tofu apply` again after the session.

Usage: load_race_data.py <bucket> <session_key> <window_start> <window_end>
       (window times in ISO 8601 UTC, for example 2025-03-16T05:08:45)
"""

import json
import logging
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

logger = logging.getLogger(__name__)

OPENF1 = "https://api.openf1.org/v1/"
WINDOW_STREAMS = [
    "car_data",
    "intervals",
    "position",
    "race_control",
    "weather",
    "pit",
    "overtakes",
]
WHOLE_RACE_STREAMS = ["laps", "stints", "drivers"]
MAX_ATTEMPTS = 6


def fetch(stream: str, params: dict) -> list:
    """Return one OpenF1 stream as a list of records, retrying on rate limits."""
    # OpenF1 filters use operators inside the key (date>=...), so keep them unescaped.
    url = f"{OPENF1}{stream}?{urllib.parse.urlencode(params, safe='<>=:')}"
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(url, timeout=120) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            # OpenF1 answers 404 when a filter matches nothing.
            if error.code == 404:
                return []
            if error.code == 401:
                detail = error.read().decode(errors="replace")
                sys.exit(
                    f"OpenF1 refused the request (401): {detail}\n"
                    "OpenF1 limits access during a live F1 session. "
                    "Run `tofu apply` again after the session ends."
                )
            if error.code != 429 or attempt == MAX_ATTEMPTS:
                raise
        delay = 2**attempt
        logger.info("rate limited on %s, retrying in %ss", stream, delay)
        time.sleep(delay)
    raise RuntimeError(f"unreachable: {stream}")


def already_loaded(destination: str) -> bool:
    """Return True when every stream file is already in the bucket."""
    listing = subprocess.run(
        ["gcloud", "storage", "ls", destination], capture_output=True, text=True, check=False
    )
    present = {line.rsplit("/", 1)[-1] for line in listing.stdout.split()}
    return all(f"{s}.json" in present for s in WINDOW_STREAMS + WHOLE_RACE_STREAMS)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    bucket, session_key, window_start, window_end = sys.argv[1:]
    destination = f"gs://{bucket}/openf1/{session_key}/"

    if already_loaded(destination):
        logger.info("race data already in %s, skipping the download", destination)
        return

    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp)
        for stream in WINDOW_STREAMS:
            records = fetch(
                stream, {"session_key": session_key, "date>": window_start, "date<": window_end}
            )
            (out / f"{stream}.json").write_text(json.dumps(records))
            logger.info("%-13s %7d records", stream, len(records))
        for stream in WHOLE_RACE_STREAMS:
            records = fetch(stream, {"session_key": session_key})
            (out / f"{stream}.json").write_text(json.dumps(records))
            logger.info("%-13s %7d records", stream, len(records))

        subprocess.run(
            ["gcloud", "storage", "cp", "--quiet", f"{tmp}/*.json", destination], check=True
        )
        logger.info("uploaded to %s", destination)


if __name__ == "__main__":
    main()
