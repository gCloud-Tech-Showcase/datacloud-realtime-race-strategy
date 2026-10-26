-- 05 Proof: flagged moments against the race
-- Compares the moments the continuous queries flagged for the latest replay
-- with what the race itself contains, worked out from the raw events with an
-- ordinary batch query. Every row should say ok = true.
DECLARE target_run STRING DEFAULT (
  SELECT run_id FROM `${project_id}.raw.raw_events`
  WHERE event_type = 'drivers'
  ORDER BY publish_time DESC LIMIT 1);

WITH expected AS (
  SELECT 'SAFETY_CAR' AS moment, COUNT(*) AS n
  FROM `${project_id}.raw.raw_events`
  WHERE run_id = target_run AND event_type = 'race_control'
    AND JSON_VALUE(payload, '$.category') = 'SafetyCar'
    AND JSON_VALUE(payload, '$.message') LIKE '%DEPLOYED%'
  UNION ALL
  SELECT 'PIT_STOP', COUNT(*)
  FROM `${project_id}.raw.raw_events`
  WHERE run_id = target_run AND event_type = 'pit'
  UNION ALL
  SELECT 'RAIN_STARTED', COUNTIF(rainfall = 1 AND previous = 0)
  FROM (
    SELECT
      SAFE.INT64(payload.rainfall) AS rainfall,
      LAG(SAFE.INT64(payload.rainfall)) OVER (ORDER BY event_ts) AS previous
    FROM `${project_id}.raw.raw_events`
    WHERE run_id = target_run AND event_type = 'weather'
  )
),

flagged AS (
  -- A moment can be flagged twice after a continuous query restarts, so count
  -- each moment once. Only moments within the race count: the smoke test in
  -- scripts/verify.sh publishes a moment stamped with today's date.
  SELECT moment, COUNT(DISTINCT TO_JSON_STRING(STRUCT(driver_number, event_ts))) AS n
  FROM `${project_id}.serving.moments`
  WHERE run_id = target_run
    AND event_ts <= (
      SELECT MAX(event_ts) FROM `${project_id}.raw.raw_events` WHERE run_id = target_run)
  GROUP BY moment
)

SELECT
  target_run AS run_id,
  e.moment,
  e.n AS expected,
  IFNULL(f.n, 0) AS flagged,
  e.n = IFNULL(f.n, 0) AS ok
FROM expected AS e
LEFT JOIN flagged AS f USING (moment)
ORDER BY e.moment;
