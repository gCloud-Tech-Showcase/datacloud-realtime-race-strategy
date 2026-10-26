-- 00 Check: replays so far
-- One row per replay: how many events landed, how many moments the continuous
-- queries flagged, and how many strategy calls succeeded or failed.
WITH run_events AS (
  SELECT run_id, COUNT(*) AS events, MIN(publish_time) AS started, MAX(publish_time) AS last_event
  FROM `${project_id}.raw.raw_events`
  GROUP BY run_id
),

run_moments AS (
  SELECT run_id, COUNT(DISTINCT TO_JSON_STRING(STRUCT(moment, driver_number, event_ts))) AS moments
  FROM `${project_id}.serving.moments`
  GROUP BY run_id
),

run_calls AS (
  SELECT run_id, COUNTIF(status = 'OK') AS calls_ok, COUNTIF(status = 'FAILED') AS calls_failed
  FROM `${project_id}.serving.calls`
  GROUP BY run_id
)

SELECT
  run_id,
  started,
  last_event,
  events,
  IFNULL(moments, 0) AS moments,
  IFNULL(calls_ok, 0) AS calls_ok,
  IFNULL(calls_failed, 0) AS calls_failed
FROM run_events
LEFT JOIN run_moments USING (run_id)
LEFT JOIN run_calls USING (run_id)
ORDER BY started DESC;
