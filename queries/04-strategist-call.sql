-- 04 Strategist: the call for one moment
-- Snapshots the field at one race moment and asks Gemini for the strategy call.
-- The strategist service runs this same script for every moment and sets the
-- five variables from the moment. Here they default to the lap-47 safety car
-- of the latest replay.
DECLARE target_run STRING DEFAULT (
  SELECT run_id FROM `${project_id}.serving.moments` ORDER BY publish_time DESC LIMIT 1);
DECLARE moment_name STRING DEFAULT 'SAFETY_CAR';
DECLARE moment_detail STRING DEFAULT 'SAFETY CAR DEPLOYED';
DECLARE moment_driver INT64 DEFAULT NULL;
DECLARE race_time TIMESTAMP DEFAULT TIMESTAMP '2025-03-16 05:41:06+00';
-- (the strategist service sets the five variables here)

WITH ev AS (
  SELECT event_type, event_ts, driver_number, payload
  FROM `${project_id}.raw.raw_events`
  WHERE run_id = target_run
    AND event_ts <= race_time
    AND event_type IN ('position', 'intervals', 'stints', 'laps', 'weather', 'drivers')
),

drivers AS (
  SELECT driver_number, ANY_VALUE(JSON_VALUE(payload, '$.name_acronym')) AS code
  FROM ev WHERE event_type = 'drivers' GROUP BY driver_number
),

positions AS (
  SELECT driver_number, ARRAY_AGG(SAFE.INT64(payload.position) ORDER BY event_ts DESC LIMIT 1)[OFFSET(0)] AS position
  FROM ev WHERE event_type = 'position' GROUP BY driver_number
),

gaps AS (
  SELECT
    driver_number,
    ARRAY_AGG(JSON_VALUE(payload, '$.gap_to_leader') ORDER BY event_ts DESC LIMIT 1)[OFFSET(0)] AS gap_to_leader,
    ARRAY_AGG(JSON_VALUE(payload, '$.interval') ORDER BY event_ts DESC LIMIT 1)[OFFSET(0)] AS interval_ahead
  FROM ev WHERE event_type = 'intervals' GROUP BY driver_number
),

stints AS (
  SELECT
    driver_number,
    ARRAY_AGG(STRUCT(
      JSON_VALUE(payload, '$.compound') AS compound,
      SAFE.INT64(payload.lap_start) AS lap_start,
      SAFE.INT64(payload.tyre_age_at_start) AS age_at_start
    ) ORDER BY event_ts DESC LIMIT 1)[OFFSET(0)] AS stint
  FROM ev WHERE event_type = 'stints' GROUP BY driver_number
),

laps AS (
  SELECT
    driver_number,
    MAX(SAFE.INT64(payload.lap_number)) AS lap,
    ARRAY_AGG(SAFE.FLOAT64(payload.lap_duration) IGNORE NULLS ORDER BY event_ts DESC LIMIT 3) AS last_laps
  FROM ev WHERE event_type = 'laps' GROUP BY driver_number
),

field AS (
  SELECT
    p.position,
    p.driver_number,
    d.code,
    g.gap_to_leader,
    g.interval_ahead,
    s.stint.compound AS compound,
    l.lap - s.stint.lap_start + s.stint.age_at_start AS tyre_age,
    l.last_laps,
    l.lap
  FROM positions AS p
  LEFT JOIN drivers AS d USING (driver_number)
  LEFT JOIN gaps AS g USING (driver_number)
  LEFT JOIN stints AS s USING (driver_number)
  LEFT JOIN laps AS l USING (driver_number)
),

context AS (
  SELECT
    MAX(lap) AS race_lap,
    STRING_AGG(
      FORMAT('P%d %s (#%d) gap %s interval %s %s tyres %s laps old, last laps %s',
        position, IFNULL(code, '?'), driver_number, IFNULL(gap_to_leader, '-'),
        IFNULL(interval_ahead, '-'), IFNULL(compound, '?'),
        IFNULL(CAST(tyre_age AS STRING), '?'), TO_JSON_STRING(last_laps)),
      '\n' ORDER BY position) AS field_text,
    (SELECT ARRAY_AGG(SAFE.INT64(payload.rainfall) ORDER BY event_ts DESC LIMIT 1)[OFFSET(0)]
      FROM ev WHERE event_type = 'weather') AS raining
  FROM field
),

-- The system instruction holds the role and the rules. The prompt holds only
-- this moment's facts. responseSchema makes Gemini answer with typed fields,
-- and the enums limit the action and the tyre to values the pit wall knows.
answer AS (
  SELECT
    race_lap,
    AI.GENERATE(
      CONCAT(
        '<context>\n',
        'Race: ${race_laps} laps. Current lap: ', IFNULL(CAST(race_lap AS STRING), 'unknown'), '. Track: ',
        IF(raining = 1, 'raining', 'dry'), '.\n',
        'Field (position, driver, gap to leader, interval to car ahead, tyre compound, tyre age, last 3 lap times in seconds):\n',
        -- Before a replay there are no cars, and a NULL here would make the
        -- whole prompt NULL.
        IFNULL(field_text, 'No cars recorded yet.'), '\n',
        '</context>\n',
        '<task>Based on the information above, the moment is: ', moment_name,
        IFNULL(CONCAT(' for ', (SELECT code FROM drivers WHERE driver_number = moment_driver),
          ' (#', CAST(moment_driver AS STRING), ')'), ''),
        ' (', moment_detail, '). Give the strategy call.</task>'),
      connection_id => '${project_id}.us.vertex-ai-connection',
      -- gemini-3.8-flash: retirement date "September 2, 2027 or later", from
      -- https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/gemini/3-8-flash
      -- (read on 2026-10-25).
      endpoint => 'https://aiplatform.googleapis.com/v1/projects/${project_id}/locations/global/publishers/google/models/gemini-3.8-flash',
      model_params => JSON '''{
        "systemInstruction": {"parts": [{"text": "You are the race strategist on an F1 pit wall. Use only the cars, gaps and tyres in the context. Do not invent drivers or data. Return at most 5 cars that should act: if the moment names a car, that car first and then its rivals around it. If no car should change plan, return an empty list."}]},
        "generationConfig": {
          "thinkingConfig": {"thinkingLevel": "LOW"},
          "responseMimeType": "application/json",
          "responseSchema": {
            "type": "OBJECT",
            "required": ["calls"],
            "properties": {"calls": {"type": "ARRAY", "maxItems": 5, "items": {
              "type": "OBJECT",
              "required": ["driver", "action", "tyre", "reason"],
              "propertyOrdering": ["driver", "action", "tyre", "reason"],
              "properties": {
                "driver": {"type": "STRING", "description": "Three-letter driver code from the context"},
                "action": {"type": "STRING", "enum": ["BOX", "STAY OUT"]},
                "tyre": {"type": "STRING", "enum": ["SOFT", "MEDIUM", "HARD", "INTERMEDIATE", "WET", "NONE"], "description": "Tyre to fit when boxing, NONE when staying out"},
                "reason": {"type": "STRING", "maxLength": 120, "description": "Why, in under 15 words"}
              }
            }}}
          }
        }
      }'''
    ) AS call
  FROM context
),

typed AS (
  SELECT
    race_lap,
    call.status,
    ARRAY(
      SELECT AS STRUCT
        JSON_VALUE(c, '$.driver') AS driver,
        JSON_VALUE(c, '$.action') AS action,
        NULLIF(JSON_VALUE(c, '$.tyre'), 'NONE') AS tyre,
        JSON_VALUE(c, '$.reason') AS reason
      FROM UNNEST(JSON_QUERY_ARRAY(SAFE.PARSE_JSON(call.result), '$.calls')) AS c WITH OFFSET AS i
      -- The schema limits the action and the tyre, not the driver: keep only
      -- cars that are in the snapshot.
      WHERE JSON_VALUE(c, '$.driver') IN (SELECT code FROM drivers)
      ORDER BY i
    ) AS actions
  FROM answer
)

-- actions is the typed answer. call_text is the same answer as one line per
-- car ("VER: BOX for INTERMEDIATE - reason"), which the pit wall shows.
SELECT
  race_lap,
  status,
  actions,
  IF(status != '', NULL, IFNULL(
    (SELECT STRING_AGG(FORMAT('%s: %s%s - %s', a.driver, a.action,
       IF(a.action = 'BOX' AND a.tyre IS NOT NULL, CONCAT(' for ', a.tyre), ''), a.reason), '\n')
     FROM UNNEST(actions) AS a),
    'No car should change plan.')) AS call_text
FROM typed;
