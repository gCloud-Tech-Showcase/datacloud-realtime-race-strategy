-- 07 Debrief: every car, every lap
-- The post-race debrief table. One row per car per completed lap, for every
-- replay, with the JSON payloads in raw.raw_events turned into typed columns:
-- position, gaps, tyres, pit stops and the weather when the lap ended, next to
-- the moments the continuous queries flagged and the calls Gemini made.
--
-- The data agent (infra/agent.tf) answers questions from this table, and
-- Knowledge Catalog scans it (infra/data_scans.tf). The apply runs it once.
-- Run it again after a replay to add that replay: it rebuilds the whole table
-- with one batch query, and BigQuery records the lineage from the three source
-- tables each time.
CREATE OR REPLACE TABLE `${project_id}.serving.lap_debrief`
CLUSTER BY run_id, driver_number
OPTIONS (
  description = 'One row per car per completed lap, for every replay. Written by the saved query 07 Debrief.',
  -- The Insights tab in BigQuery shows the Knowledge Catalog insights scan
  -- named here (infra/data_scans.tf). CREATE OR REPLACE drops labels, so they
  -- are set on every run.
  labels = [
    ('dataplex-data-documentation-published-scan', 'lap-debrief-insights'),
    ('dataplex-data-documentation-published-project', '${project_id}'),
    ('dataplex-data-documentation-published-location', '${region}')
  ]
)
AS
WITH ev AS (
  SELECT run_id, event_type, event_ts, publish_time, driver_number, payload
  FROM `${project_id}.raw.raw_events`
  WHERE event_type IN ('drivers', 'laps', 'position', 'intervals', 'stints', 'pit', 'weather')
),

-- When each replay ran. Race times repeat across replays, publish times do not.
replays AS (
  SELECT run_id, MIN(publish_time) AS replayed_at
  FROM ev WHERE event_type = 'drivers'
  GROUP BY run_id
),

drivers AS (
  SELECT
    run_id,
    driver_number,
    ANY_VALUE(JSON_VALUE(payload, '$.name_acronym')) AS driver,
    ANY_VALUE(JSON_VALUE(payload, '$.team_name')) AS team
  FROM ev WHERE event_type = 'drivers'
  GROUP BY run_id, driver_number
),

-- A lap is published when it ends, so its event_ts is the end of the lap.
-- Pub/Sub can deliver a message twice: keep the first copy.
laps AS (
  SELECT
    run_id,
    driver_number,
    SAFE.INT64(payload.lap_number) AS lap,
    event_ts AS lap_end_ts,
    SAFE.FLOAT64(payload.lap_duration) AS lap_s,
    SAFE.BOOL(payload.is_pit_out_lap) AS pit_out_lap
  FROM ev WHERE event_type = 'laps'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY run_id, driver_number, lap ORDER BY publish_time) = 1
),

-- The latest reading at or before the end of each lap.
positions AS (
  SELECT l.run_id, l.driver_number, l.lap, SAFE.INT64(e.payload.position) AS position
  FROM laps AS l
  JOIN ev AS e
    ON e.event_type = 'position' AND e.run_id = l.run_id
    AND e.driver_number = l.driver_number AND e.event_ts <= l.lap_end_ts
  QUALIFY ROW_NUMBER() OVER (PARTITION BY l.run_id, l.driver_number, l.lap ORDER BY e.event_ts DESC) = 1
),

-- gap_to_leader and interval are numbers, or text such as "+1 LAP".
gaps AS (
  SELECT
    l.run_id, l.driver_number, l.lap,
    SAFE.FLOAT64(e.payload.gap_to_leader) AS gap_to_leader_s,
    SAFE.FLOAT64(e.payload.`interval`) AS interval_s
  FROM laps AS l
  JOIN ev AS e
    ON e.event_type = 'intervals' AND e.run_id = l.run_id
    AND e.driver_number = l.driver_number AND e.event_ts <= l.lap_end_ts
  QUALIFY ROW_NUMBER() OVER (PARTITION BY l.run_id, l.driver_number, l.lap ORDER BY e.event_ts DESC) = 1
),

-- The stint a lap belongs to. A stint is published again with lap_end once it
-- ends, so take the latest stint that started on or before the lap.
tyres AS (
  SELECT
    l.run_id, l.driver_number, l.lap,
    JSON_VALUE(e.payload, '$.compound') AS compound,
    l.lap - SAFE.INT64(e.payload.lap_start) + SAFE.INT64(e.payload.tyre_age_at_start) AS tyre_age_laps
  FROM laps AS l
  JOIN ev AS e
    ON e.event_type = 'stints' AND e.run_id = l.run_id
    AND e.driver_number = l.driver_number AND SAFE.INT64(e.payload.lap_start) <= l.lap
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY l.run_id, l.driver_number, l.lap
    ORDER BY SAFE.INT64(e.payload.stint_number) DESC, e.event_ts DESC) = 1
),

pits AS (
  SELECT
    run_id,
    driver_number,
    SAFE.INT64(payload.lap_number) AS lap,
    SAFE.FLOAT64(payload.lane_duration) AS pit_lane_s,
    SAFE.FLOAT64(payload.stop_duration) AS stop_s
  FROM ev WHERE event_type = 'pit'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY run_id, driver_number, lap ORDER BY publish_time) = 1
),

weather AS (
  SELECT l.run_id, l.driver_number, l.lap, SAFE.INT64(e.payload.rainfall) = 1 AS raining
  FROM laps AS l
  JOIN ev AS e
    ON e.event_type = 'weather' AND e.run_id = l.run_id AND e.event_ts <= l.lap_end_ts
  QUALIFY ROW_NUMBER() OVER (PARTITION BY l.run_id, l.driver_number, l.lap ORDER BY e.event_ts DESC) = 1
),

-- A GAP_CLOSING moment has no lap, so it goes on the first lap the car
-- finished at or after the moment. Calls answer one moment each, through the
-- moment's Pub/Sub message ID. A moment can be flagged twice after a
-- continuous query restarts: list it once.
car_moments AS (
  SELECT m.run_id, m.driver_number, IFNULL(m.lap, l.lap) AS lap, m.moment, m.message_id
  FROM `${project_id}.serving.moments` AS m
  LEFT JOIN laps AS l
    ON m.lap IS NULL AND l.run_id = m.run_id
    AND l.driver_number = m.driver_number AND l.lap_end_ts >= m.event_ts
  WHERE m.driver_number IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY m.run_id, m.driver_number, m.moment, m.event_ts ORDER BY l.lap_end_ts) = 1
),

moments AS (
  SELECT
    m.run_id,
    m.driver_number,
    m.lap,
    ARRAY_AGG(DISTINCT m.moment ORDER BY m.moment) AS moments,
    ARRAY_AGG(c.call_text IGNORE NULLS ORDER BY c.created_at LIMIT 1)[SAFE_OFFSET(0)] AS call_text
  FROM car_moments AS m
  LEFT JOIN `${project_id}.serving.calls` AS c
    ON c.moment_message_id = m.message_id AND c.status = 'OK'
  WHERE m.lap IS NOT NULL
  GROUP BY m.run_id, m.driver_number, m.lap
)

SELECT
  l.run_id,
  r.replayed_at,
  l.lap,
  l.driver_number,
  d.driver,
  d.team,
  p.position,
  l.lap_s,
  g.gap_to_leader_s,
  g.interval_s,
  t.compound,
  t.tyre_age_laps,
  pt.lap IS NOT NULL AS pitted,
  pt.pit_lane_s,
  pt.stop_s,
  IFNULL(l.pit_out_lap, FALSE) AS pit_out_lap,
  IFNULL(w.raining, FALSE) AS raining,
  IFNULL(m.moments, []) AS moments,
  m.call_text,
  l.lap_end_ts
FROM laps AS l
JOIN replays AS r USING (run_id)
LEFT JOIN drivers AS d USING (run_id, driver_number)
LEFT JOIN positions AS p USING (run_id, driver_number, lap)
LEFT JOIN gaps AS g USING (run_id, driver_number, lap)
LEFT JOIN tyres AS t USING (run_id, driver_number, lap)
LEFT JOIN pits AS pt USING (run_id, driver_number, lap)
LEFT JOIN weather AS w USING (run_id, driver_number, lap)
LEFT JOIN moments AS m USING (run_id, driver_number, lap)
WHERE l.lap IS NOT NULL;

-- The latest replay, lap by lap for the top five.
SELECT lap, position, driver, team, lap_s, compound, tyre_age_laps, pitted, raining, moments
FROM `${project_id}.serving.lap_debrief`
WHERE run_id = (SELECT run_id FROM `${project_id}.serving.lap_debrief` ORDER BY replayed_at DESC LIMIT 1)
  AND position <= 5
ORDER BY lap DESC, position
LIMIT 25;
