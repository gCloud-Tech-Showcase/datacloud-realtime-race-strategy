-- 03b Moments: windowed rules (continuous query)
-- Flags race moments that need several events over time, using one TUMBLE
-- window (Preview). Windows close on arrival time in BigQuery, not race time,
-- and results arrive in batches about once a minute. Run it as a continuous
-- query, as the cq-runner service account.
--
-- One aggregation serves both rules: weather rows have no driver, so they form
-- their own group, and interval rows group per driver. Several TUMBLE
-- aggregations joined with UNION ALL emitted nothing (verified on 2026-10-25).
EXPORT DATA OPTIONS (
  format = 'CLOUD_PUBSUB',
  uri = 'https://pubsub.googleapis.com/projects/${project_id}/topics/race-moments'
) AS (
  WITH ev AS (
    SELECT
      _CHANGE_TIMESTAMP AS ct,
      run_id,
      event_type,
      event_ts,
      driver_number,
      CASE event_type
        WHEN 'weather' THEN SAFE.FLOAT64(payload.rainfall)
        WHEN 'intervals' THEN SAFE.FLOAT64(payload.interval)
      END AS value
    -- Change history lags the writes, so the start time sits 10 minutes back.
    -- A start time after the readable end fails with "Invalid timestamp bounds".
    FROM APPENDS(TABLE `${project_id}.raw.raw_events`, CURRENT_TIMESTAMP() - INTERVAL 10 MINUTE)
    WHERE event_type IN ('weather', 'intervals')
  ),

  windows AS (
    SELECT
      run_id,
      driver_number,
      ANY_VALUE(event_type) AS event_type,
      MIN_BY(value, event_ts) AS first_value,
      MAX_BY(value, event_ts) AS last_value,
      MAX(event_ts) AS event_ts
    FROM TUMBLE(TABLE ev, "ct", INTERVAL ${window_seconds} SECOND)
    GROUP BY window_end, run_id, driver_number
  )

  SELECT TO_JSON_STRING(STRUCT(
    run_id,
    IF(event_type = 'weather', 'RAIN_STARTED', 'GAP_CLOSING') AS moment,
    driver_number,
    CAST(NULL AS INT64) AS lap,
    event_ts,
    IF(event_type = 'weather',
      'rainfall 0 -> 1',
      FORMAT('gap to car ahead %.3f s -> %.3f s', first_value, last_value)) AS detail
  )) AS message
  FROM windows
  WHERE
    -- Rain: the window starts dry and ends wet.
    (event_type = 'weather' AND first_value = 0 AND last_value = 1)
    -- Gap closing: the gap to the car ahead shrinks and ends inside DRS range.
    OR (event_type = 'intervals'
      AND first_value - last_value >= ${gap_closing_seconds}
      AND last_value < 1.0)
);
