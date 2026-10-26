"""Strategist: turn each race moment into a strategy call.

Receives race-moments messages as Pub/Sub pushes. For each moment it runs the
strategist script (queries/04-strategist-call.sql, rendered by tofu apply),
which snapshots the field in BigQuery and calls Gemini through AI.GENERATE.
The call lands in serving.calls.

Each moment is answered once. Pub/Sub delivers at least once, and the
continuous queries can flag a moment again after a restart, so a moment that
already has a call is acknowledged without a second Gemini request.

Only the moments in CALL_MOMENTS get a call. A pit stop alone does not: under
a safety car most of the field pits within a minute, and a call per stop
repeats itself and queues the calls that matter.

A failed call is never hidden: the error is logged at ERROR with the model ID,
and the row is written with status FAILED, so the pit wall shows it.
"""

import base64
import json
import logging
import os
import time
from datetime import UTC, datetime

from flask import Flask, request
from google.cloud import bigquery

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
logger = logging.getLogger(__name__)

PROJECT_ID = os.environ["PROJECT_ID"]
CALLS_TABLE = os.environ["CALLS_TABLE"]
MODEL = os.environ["MODEL"]
STRATEGIST_SQL = os.environ["STRATEGIST_SQL"]
CALL_MOMENTS = set(os.environ["CALL_MOMENTS"].split(","))
VARIABLES_MARKER = "-- (the strategist service sets the five variables here)"

SET_VARIABLES = """
SET target_run = @run_id;
SET moment_name = @moment;
SET moment_detail = @detail;
SET race_time = @race_time;
SET moment_driver = @driver_number;
"""

if VARIABLES_MARKER not in STRATEGIST_SQL:
    raise ValueError("STRATEGIST_SQL has no variables marker")
SCRIPT = STRATEGIST_SQL.replace(VARIABLES_MARKER, SET_VARIABLES)

bq = bigquery.Client(project=PROJECT_ID)
app = Flask(__name__)


def already_answered(moment: dict) -> bool:
    job = bq.query(
        f"""
        SELECT 1 FROM `{CALLS_TABLE}`
        WHERE run_id = @run_id AND moment = @moment AND event_ts = @event_ts
          AND driver_number IS NOT DISTINCT FROM @driver_number
        LIMIT 1
        """,
        job_config=bigquery.QueryJobConfig(
            query_parameters=[
                bigquery.ScalarQueryParameter("run_id", "STRING", moment["run_id"]),
                bigquery.ScalarQueryParameter("moment", "STRING", moment["moment"]),
                bigquery.ScalarQueryParameter("event_ts", "TIMESTAMP", moment["event_ts"]),
                bigquery.ScalarQueryParameter("driver_number", "INT64", moment["driver_number"]),
            ]
        ),
    )
    return any(True for _ in job.result())


def make_call(moment: dict) -> tuple[int | None, str, str | None]:
    """Return (race lap, call text, error). Error is None when Gemini answered."""
    job = bq.query(
        SCRIPT,
        job_config=bigquery.QueryJobConfig(
            query_parameters=[
                bigquery.ScalarQueryParameter("run_id", "STRING", moment["run_id"]),
                bigquery.ScalarQueryParameter("moment", "STRING", moment["moment"]),
                bigquery.ScalarQueryParameter("detail", "STRING", moment.get("detail") or ""),
                bigquery.ScalarQueryParameter("race_time", "TIMESTAMP", moment["event_ts"]),
                bigquery.ScalarQueryParameter("driver_number", "INT64", moment["driver_number"]),
            ]
        ),
    )
    row = next(iter(job.result()))
    call = row["call"] or {}
    status = call.get("status") or ""
    text = call.get("result") or ""
    if not status and not text:
        status = "Gemini returned no text"
    return row["race_lap"], text, status or None


@app.post("/")
def handle_push():
    envelope = request.get_json(silent=True) or {}
    message = envelope.get("message", {})
    moment = json.loads(base64.b64decode(message.get("data", "")) or b"{}")
    if not moment.get("run_id") or not moment.get("moment"):
        logger.warning("ignoring a message without run_id or moment: %s", message.get("messageId"))
        return "", 204

    if moment["moment"] not in CALL_MOMENTS:
        return "", 204

    if already_answered(moment):
        logger.info("already answered %s %s", moment["moment"], moment["event_ts"])
        return "", 204

    started = time.monotonic()
    try:
        lap, call_text, error = make_call(moment)
    except Exception as exc:
        # Top-level isolation point: any failure becomes a visible FAILED call
        # instead of a silent retry loop.
        logger.exception("strategist query failed for %s with model %s", moment["moment"], MODEL)
        lap, call_text, error = moment.get("lap"), "", str(exc)

    if error:
        logger.error(
            "Gemini call failed: model=%s moment=%s error=%s", MODEL, moment["moment"], error
        )

    errors = bq.insert_rows_json(
        CALLS_TABLE,
        [
            {
                "run_id": moment["run_id"],
                "moment_message_id": message.get("messageId"),
                "moment": moment["moment"],
                "driver_number": moment.get("driver_number"),
                "lap": lap,
                "event_ts": moment["event_ts"],
                "status": "FAILED" if error else "OK",
                "call_text": call_text,
                "error": error,
                "model": MODEL,
                "latency_ms": int((time.monotonic() - started) * 1000),
                "created_at": datetime.now(UTC).isoformat(),
            }
        ],
    )
    if errors:
        logger.error("could not write the call: %s", errors)
        return "write failed", 500

    logger.info("%s on lap %s answered in %.1fs", moment["moment"], lap, time.monotonic() - started)
    return "", 204
