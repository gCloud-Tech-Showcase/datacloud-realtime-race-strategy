-- 02 Events: what landed for the latest replay
-- Counts the events of the latest replay by type, as the BigQuery subscription
-- wrote them, with the race time each type has reached.
DECLARE target_run STRING DEFAULT (
  SELECT run_id FROM `${project_id}.raw.raw_events`
  WHERE event_type = 'drivers'
  ORDER BY publish_time DESC LIMIT 1);

SELECT
  event_type,
  COUNT(*) AS events,
  MAX(event_ts) AS latest_race_time,
  MAX(publish_time) AS latest_publish_time
FROM `${project_id}.raw.raw_events`
WHERE run_id = target_run
GROUP BY event_type
ORDER BY events DESC;
