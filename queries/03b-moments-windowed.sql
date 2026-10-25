-- 03b Moments: gap closing (continuous query, windowed)
-- Flags a car closing on the car ahead, using a TUMBLE window (Preview).
-- Windows close on arrival time in BigQuery, not race time, and results arrive
-- in batches about once a minute. Run it as a continuous query, as the
-- cq-runner service account.
EXPORT DATA OPTIONS (
  format = 'CLOUD_PUBSUB',
  uri = 'https://pubsub.googleapis.com/projects/${project_id}/topics/race-moments'
) AS (
  WITH ev AS (
    SELECT
      _CHANGE_TIMESTAMP AS ct,
      run_id,
      event_ts,
      driver_number,
      SAFE.FLOAT64(payload.interval) AS gap
    -- Change history lags the writes, so the start time sits 10 minutes back.
    -- A start time after the readable end fails with "Invalid timestamp bounds".
    FROM APPENDS(TABLE `${project_id}.raw.raw_events`, CURRENT_TIMESTAMP() - INTERVAL 10 MINUTE)
    WHERE event_type = 'intervals'
  ),

  windows AS (
    SELECT
      run_id,
      driver_number,
      MIN_BY(gap, event_ts) AS gap_first,
      MAX_BY(gap, event_ts) AS gap_last,
      MAX(event_ts) AS event_ts
    FROM TUMBLE(TABLE ev, "ct", INTERVAL ${window_seconds} SECOND)
    GROUP BY window_end, run_id, driver_number
  )

  SELECT TO_JSON_STRING(STRUCT(
    run_id,
    'GAP_CLOSING' AS moment,
    driver_number,
    CAST(NULL AS INT64) AS lap,
    event_ts,
    FORMAT('gap to car ahead %.3f s -> %.3f s', gap_first, gap_last) AS detail
  )) AS message
  FROM windows
  -- The gap shrinks by at least gap_closing_seconds and ends inside DRS range.
  WHERE gap_first - gap_last >= ${gap_closing_seconds} AND gap_last < 1.0
);
