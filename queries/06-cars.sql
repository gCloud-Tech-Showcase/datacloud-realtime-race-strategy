-- 06 Cars: what Gemini reads in a photo
-- Reads one photo per team with Gemini and writes what it sees to
-- serving.cars. The photos are files in Cloud Storage, and raw.car_photos is
-- an object table over them: one row per file, with an ObjectRef in `ref`
-- that AI.GENERATE reads like any other column.
--
-- `team` comes from the photo's own metadata (media/car_photos.json), not from
-- Gemini, so the pit wall never shows a wrong photo.
--
-- The apply runs this once. Running it again makes 10 Gemini requests.
CREATE OR REPLACE TABLE `${project_id}.serving.cars`
OPTIONS (description = 'What Gemini read in each car photo. Written by the saved query 06 Cars.')
AS
WITH photos AS (
  SELECT
    uri,
    ref,
    (SELECT value FROM UNNEST(metadata) WHERE name = 'team') AS team
  FROM `${project_id}.raw.car_photos`
),

-- Only lists are asked for. A plain text field, such as the team name,
-- sometimes received the model's reasoning instead of an answer, and car
-- numbers came from past seasons for 3 of 10 cars (seen on 2026-10-27).
answers AS (
  SELECT
    uri,
    team,
    AI.GENERATE(
      ('This is a photo of a 2025 Formula 1 car. '
        || 'livery_colours: up to 3 main colours of the car. '
        || 'sponsors: every brand name you can read on the car, as printed.', ref),
      connection_id => '${project_id}.us.vertex-ai-connection',
      -- Gemini 3.8 Flash retires on September 2, 2027 or later (#2).
      endpoint => 'https://aiplatform.googleapis.com/v1/projects/${project_id}/locations/global/publishers/google/models/gemini-3.8-flash',
      model_params => JSON '{"generationConfig": {"thinkingConfig": {"thinkingLevel": "LOW"}}}',
      output_schema => 'livery_colours ARRAY<STRING>, sponsors ARRAY<STRING>'
    ) AS answer
  FROM photos
)

SELECT
  team,
  uri,
  answer.livery_colours,
  answer.sponsors,
  answer.status,
  CURRENT_TIMESTAMP() AS read_at
FROM answers;

SELECT
  team,
  ARRAY_TO_STRING(livery_colours, ', ') AS colours,
  ARRAY_LENGTH(sponsors) AS sponsors_read,
  ARRAY_TO_STRING(sponsors, ', ') AS sponsors,
  status
FROM `${project_id}.serving.cars`
ORDER BY team;
