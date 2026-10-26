-- 04b Calls: the strategist's answers
-- Lists the strategy calls of the latest replay, oldest first, with how long
-- each took from receiving the moment to writing the call.
DECLARE target_run STRING DEFAULT (
  SELECT run_id FROM `${project_id}.raw.raw_events`
  WHERE event_type = 'drivers'
  ORDER BY publish_time DESC LIMIT 1);

SELECT
  c.moment,
  c.lap,
  d.code AS driver,
  c.event_ts AS race_time,
  c.status,
  ROUND(c.latency_ms / 1000, 1) AS seconds,
  c.call_text,
  c.error
FROM `${project_id}.serving.calls` AS c
LEFT JOIN (
  SELECT driver_number, ANY_VALUE(JSON_VALUE(payload, '$.name_acronym')) AS code
  FROM `${project_id}.raw.raw_events`
  WHERE run_id = target_run AND event_type = 'drivers'
  GROUP BY driver_number
) AS d ON d.driver_number = c.driver_number
WHERE c.run_id = target_run
ORDER BY c.event_ts;
