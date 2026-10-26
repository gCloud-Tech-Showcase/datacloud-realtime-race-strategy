-- 03c Moments: what the continuous queries flagged
-- Lists the moments of the latest replay, oldest first. seconds_after_event is
-- the time from the event landing in BigQuery to the moment reaching Pub/Sub.
DECLARE target_run STRING DEFAULT (
  SELECT run_id FROM `${project_id}.raw.raw_events`
  WHERE event_type = 'drivers'
  ORDER BY publish_time DESC LIMIT 1);

SELECT
  m.moment,
  m.lap,
  d.code AS driver,
  m.event_ts AS race_time,
  m.detail,
  ROUND(TIMESTAMP_DIFF(m.publish_time, MIN(r.publish_time), MILLISECOND) / 1000, 1) AS seconds_after_event
FROM `${project_id}.serving.moments` AS m
LEFT JOIN `${project_id}.raw.raw_events` AS r
  ON r.run_id = m.run_id AND r.event_ts = m.event_ts
  AND r.driver_number IS NOT DISTINCT FROM m.driver_number
LEFT JOIN (
  SELECT driver_number, ANY_VALUE(JSON_VALUE(payload, '$.name_acronym')) AS code
  FROM `${project_id}.raw.raw_events`
  WHERE run_id = target_run AND event_type = 'drivers'
  GROUP BY driver_number
) AS d ON d.driver_number = m.driver_number
WHERE m.run_id = target_run
GROUP BY m.moment, m.lap, d.code, m.event_ts, m.detail, m.publish_time
ORDER BY m.event_ts;
