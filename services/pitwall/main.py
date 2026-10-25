"""Pit wall: a small web app that shows one replay live.

Serves one page and a JSON API:
  GET  /api/state?run_id=...      timing tower, moments, calls and race clock
  POST /api/start                 runs the replayer job with a new run_id
  POST /api/queries/start         starts both continuous queries
  POST /api/queries/stop          cancels the continuous queries it started

The browser holds the run_id and the continuous query job IDs, so the server
keeps no state between requests. The continuous queries start only after the
replay has written its first events: a continuous query started on an idle
table fails with "Invalid timestamp bounds".
"""

import logging
import os
import uuid

import google.auth
from flask import Flask, jsonify, request, send_from_directory
from google.auth.transport.requests import AuthorizedSession
from google.cloud import bigquery

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
logger = logging.getLogger(__name__)

PROJECT_ID = os.environ["PROJECT_ID"]
REGION = os.environ["REGION"]
LOCATION = os.environ["BQ_LOCATION"]
REPLAYER_JOB = os.environ["REPLAYER_JOB"]
CQ_SERVICE_ACCOUNT = os.environ["CQ_SERVICE_ACCOUNT"]
CONTINUOUS_QUERIES = {
    "moments-fast": os.environ["MOMENTS_FAST_SQL"],
    "moments-windowed": os.environ["MOMENTS_WINDOWED_SQL"],
}

_credentials, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
session = AuthorizedSession(_credentials)
bq = bigquery.Client(project=PROJECT_ID)
app = Flask(__name__, static_folder="static")


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
  d.driver_number, d.code, d.colour,
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
SELECT moment, driver_number, lap, event_ts, detail, publish_time
FROM `{project}.serving.moments`
WHERE run_id = @run_id
QUALIFY ROW_NUMBER() OVER (PARTITION BY moment, driver_number, event_ts ORDER BY publish_time) = 1
ORDER BY event_ts DESC
LIMIT 50
"""

CALLS_SQL = """
SELECT moment, driver_number, lap, event_ts, status, call_text, error, latency_ms, created_at
FROM `{project}.serving.calls`
WHERE run_id = @run_id
ORDER BY event_ts DESC
LIMIT 20
"""

CLOCK_SQL = """
SELECT COUNT(*) AS events, MAX(event_ts) AS race_time, MAX(publish_time) AS last_publish
FROM `{project}.raw.raw_events`
WHERE run_id = @run_id
"""


def _jsonable(rows: list[dict]) -> list[dict]:
    return [
        {k: (v.isoformat() if hasattr(v, "isoformat") else v) for k, v in row.items()}
        for row in rows
    ]


@app.get("/")
def index():
    return send_from_directory(app.static_folder, "index.html")


@app.get("/api/state")
def state():
    run_id = request.args.get("run_id", "")
    if not run_id:
        return jsonify({"error": "run_id is required"}), 400
    return jsonify(
        {
            "clock": _jsonable(run_query(CLOCK_SQL.format(project=PROJECT_ID), run_id))[0],
            "timing": _jsonable(run_query(TIMING_SQL.format(project=PROJECT_ID), run_id)),
            "moments": _jsonable(run_query(MOMENTS_SQL.format(project=PROJECT_ID), run_id)),
            "calls": _jsonable(run_query(CALLS_SQL.format(project=PROJECT_ID), run_id)),
        }
    )


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
