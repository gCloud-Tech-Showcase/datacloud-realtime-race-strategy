-- 03a Moments: fast rules (continuous query)
-- Flags race moments that one event shows on its own, and publishes each to the
-- race-moments topic within seconds. Run it as a continuous query, as the
-- cq-runner service account.
EXPORT DATA OPTIONS (
  format = 'CLOUD_PUBSUB',
  uri = 'https://pubsub.googleapis.com/projects/${project_id}/topics/race-moments'
) AS (
  SELECT TO_JSON_STRING(STRUCT(run_id, moment, driver_number, lap, event_ts, detail)) AS message
  FROM (
    SELECT
      run_id,
      CASE
        WHEN event_type = 'race_control'
          AND JSON_VALUE(payload, '$.category') = 'SafetyCar'
          AND JSON_VALUE(payload, '$.message') LIKE '%DEPLOYED%' THEN 'SAFETY_CAR'
        WHEN event_type = 'pit' THEN 'PIT_STOP'
      END AS moment,
      driver_number,
      SAFE.INT64(payload.lap_number) AS lap,
      event_ts,
      CASE
        WHEN event_type = 'race_control' THEN JSON_VALUE(payload, '$.message')
        ELSE FORMAT('pit lane %s s', JSON_VALUE(payload, '$.lane_duration'))
      END AS detail
    -- Change history lags the writes, so the start time sits 10 minutes back.
    -- A start time after the readable end fails with "Invalid timestamp bounds"
    -- (verified on 2026-10-25). A moment from an earlier run can be flagged
    -- again, so the strategist answers each moment once.
    FROM APPENDS(TABLE `${project_id}.raw.raw_events`, CURRENT_TIMESTAMP() - INTERVAL 10 MINUTE)
    WHERE event_type IN ('race_control', 'pit')
  )
  WHERE moment IS NOT NULL
);
