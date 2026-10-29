# Race Strategy

You replay laps 30 to 50 of the 2025 Australian Grand Prix as if they were live. You watch race events stream into BigQuery, see continuous queries flag the moments that matter within seconds, and read the strategy call that Gemini makes for each one, from a query in BigQuery.

You can follow the same steps in Python: open **BigQuery Studio > Notebooks > 01 Race Strategy**. When it asks for a runtime, choose **Runtime > Connect to a runtime > Create new runtime** and the **F1 Pit Wall: Real-Time Race Strategy notebooks** template. Every query in this guide is also a saved query under **BigQuery Studio > Queries**, named next to its block.

Run all commands from the repository root, with `PROJECT_ID` set to your project:

```bash
PROJECT_ID=<your-project-id>
```

| Step | What you do | What you see |
| --- | --- | --- |
| Before you start | Check the deployment | `READY` |
| 1 | Open the pit wall and start the race | The timing tower fills with 20 cars |
| 2 | Look at the events landing in BigQuery | About 195,000 events over the replay |
| 3 | Read the two continuous queries | Safety cars, pit stops and rain within seconds, gap closing within a minute |
| 4 | Read the strategy calls | One call per safety car, rain start and gap closing |
| 5 | Prove it | Every moment the race contains, flagged once |
| 6 (optional) | Read the cars in the photos | Colours and sponsors for each team, from one photo each |
| Stop | Cancel the continuous queries | Nothing billing for slots |

---

## Before you start

```bash
./scripts/verify.sh --expect READY
```

To see earlier replays, run the saved query **00 Check: replays so far** (`queries/00-replays.sql`).

---

## Step 1: Open the pit wall and start the race

The pit wall is a private Cloud Run service. Open it through a local proxy that signs your requests:

```bash
gcloud run services proxy pitwall --region=us-central1 --project="$PROJECT_ID"
```

Open http://localhost:8080 and press **Start race**.

1. The page runs the `replayer` Cloud Run job with a new `run_id`. The job reads the race from the bucket and publishes it to the `race-events` topic at five times real time. It needs between 20 seconds and 4 minutes to start: the first run in a new project is the slowest (verified on 2026-10-26).
2. When the first events land, the page starts the two continuous queries. A continuous query started on an idle table fails, so the page waits for the events.
3. The timing tower fills with all 20 cars, their gaps and their tyres. The strip above it places each car by its gap to the leader. The window is 42 minutes of racing, so at five times real time it plays for about 8.5 minutes.
4. Each safety car, rain start and gap closing appears on the right as a card. The card lists Gemini's call for each car, and whether that car really pitted around that lap. Pit stops are grouped into one line per burst.
5. A minute after the last lap of the window, the page cancels the two continuous queries.

---

## Step 2: Look at the events landing in BigQuery

Every message on `race-events` lands in `raw.raw_events` through a BigQuery subscription. Saved query **02 Events: what landed for the latest replay**:

```sql
DECLARE target_run STRING DEFAULT (
  SELECT run_id FROM `<project>.raw.raw_events`
  WHERE event_type = 'drivers'
  ORDER BY publish_time DESC LIMIT 1);

SELECT
  event_type,
  COUNT(*) AS events,
  MAX(event_ts) AS latest_race_time,
  MAX(publish_time) AS latest_publish_time
FROM `<project>.raw.raw_events`
WHERE run_id = target_run
GROUP BY event_type
ORDER BY events DESC;
```

Run it a few times. `car_data` grows by about 74 rows per second of race time (20 cars at about 3.7 Hz), and `latest_race_time` moves forward five times faster than the clock.

Each row keeps the OpenF1 record as published in `payload`. The message format is in [Architecture](architecture.md#race-event-message).

---

## Step 3: Read the two continuous queries

Open the saved query **03a Moments: fast rules (continuous query)**. It reads every row as it lands, with `APPENDS`, and publishes a moment to `race-moments` when one event is enough:

| Moment | Rule |
| --- | --- |
| `SAFETY_CAR` | A race control message in the `SafetyCar` category that says `DEPLOYED` |
| `PIT_STOP` | A pit event |
| `RAIN_STARTED` | A weather reading with `rainfall = 1` after one with `rainfall = 0` |

Open **03b Moments: gap closing (continuous query, windowed)**. It groups the interval readings of each car into 30-second `TUMBLE` windows, and flags a car whose gap to the car ahead shrinks by a second or more and ends inside a second.

The pit wall started both. To start one yourself, open it in BigQuery Studio, choose **More > Query settings > Continuous query**, set the service account to `cq-runner@<project>.iam.gserviceaccount.com`, and run it.

Then see what they flagged. Saved query **03c Moments: what the continuous queries flagged** lists the moments of the latest replay, with the seconds from the event landing to the moment reaching Pub/Sub:

| moment | lap | driver | race_time | detail | seconds_after_event |
| --- | --- | --- | --- | --- | --- |
| `SAFETY_CAR` | 34 | | 05:15:09 | SAFETY CAR DEPLOYED | 4.0 |
| `PIT_STOP` | 33 | TSU | 05:15:54 | pit lane 18.997 s | 3.4 |
| `PIT_STOP` | 33 | ALB | 05:15:55 | pit lane 18.573 s | 3.4 |

*Sample output from a replay on 2026-10-25. Your values change with every run.*

The two queries behave differently (verified on 2026-10-25):

| Query | Event to moment |
| --- | --- |
| 03a, one row at a time | 3 to 6 seconds |
| 03b, `TUMBLE` windows | 40 to 70 seconds, in batches about once a minute |

`TUMBLE` windows close on the time a row arrives in BigQuery, not on race time. At five times real time, a 30-second window covers 2.5 minutes of racing.

---

## Step 4: Read the strategy calls

The `strategist` Cloud Run service receives every moment as a Pub/Sub push. For a safety car, a rain start or a gap closing, it runs one BigQuery script: a snapshot of the field at that race time, then `AI.GENERATE` with `gemini-3.8-flash`. Pit stops get no call of their own: under a safety car most of the field pits within a minute.

Open the saved query **04 Strategist: the call for one moment**. It is the exact script the service runs, with the lap 47 safety car of the latest replay filled in. Run it to see Gemini make the call from SQL.

Then read all the calls of the replay. Saved query **04b Calls: the strategist's answers**:

```sql
DECLARE target_run STRING DEFAULT (
  SELECT run_id FROM `<project>.raw.raw_events`
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
FROM `<project>.serving.calls` AS c
LEFT JOIN (
  SELECT driver_number, ANY_VALUE(JSON_VALUE(payload, '$.name_acronym')) AS code
  FROM `<project>.raw.raw_events`
  WHERE run_id = target_run AND event_type = 'drivers'
  GROUP BY driver_number
) AS d ON d.driver_number = c.driver_number
WHERE c.run_id = target_run
ORDER BY c.event_ts;
```

A call for the rain start on lap 44:

```text
VER: BOX for INTERMEDIATE; rain active, slick pace dropping, midfield already switched.
TSU: BOX for INTERMEDIATE; rain active, cover cars behind pitting for wet weather tyres.
HAM: BOX for INTERMEDIATE; track wet, slick tyres unviable as field transitions.
GAS: BOX for INTERMEDIATE; rain started, switch to intermediate to avoid losing time.
LEC: BOX for INTERMEDIATE; track wet, lap times falling sharply on hard tyres.
```

*From a replay on 2026-10-25, 4.1 seconds after the moment arrived.*

When Gemini fails, the call is written with `status = 'FAILED'` and the error, and the pit wall shows it in red. Nothing falls back silently.

---

## Step 5: Prove it

Saved query **05 Proof: flagged moments against the race** works out from the raw events, with an ordinary batch query, which moments the race contains, and compares them with what the continuous queries flagged:

| run_id | moment | expected | flagged | ok |
| --- | --- | --- | --- | --- |
| run-184b04fc | PIT_STOP | 31 | 31 | true |
| run-184b04fc | RAIN_STARTED | 1 | 1 | true |
| run-184b04fc | SAFETY_CAR | 2 | 2 | true |

*Sample output from a replay on 2026-10-25.*

Every row says `ok = true`. If one says `false`, a continuous query missed a moment. Check that both were running in **BigQuery > Jobs explorer**.

---

## Step 6 (optional): Read the cars in the photos

Files can be rows too. The apply downloaded one photo per team into the race-data bucket, and `raw.car_photos` is an object table over them: one row per file, with its metadata and an ObjectRef in `ref`. The photos stay outside the live race. Nothing in Steps 1 to 5 reads them.

Open the saved query **06 Cars: what Gemini reads in a photo**. It passes each `ref` to the same `AI.GENERATE` function that the strategist uses, asks for the livery colours and the sponsors, and writes the answers to `serving.cars`. The apply already ran it once. Run it to read the photos again, which makes 10 Gemini requests.

```sql
AI.GENERATE(
  ('This is a photo of a 2025 Formula 1 car. '
    || 'livery_colours: up to 3 main colours of the car. '
    || 'sponsors: every brand name you can read on the car, as printed.', ref),
  connection_id => '<project>.us.vertex-ai-connection',
  endpoint => '.../models/gemini-3.8-flash',
  model_params => JSON '{"generationConfig": {"thinkingConfig": {"thinkingLevel": "LOW"}}}',
  output_schema => 'livery_colours ARRAY<STRING>, sponsors ARRAY<STRING>'
)
```

| team | colours | sponsors_read | sponsors |
| --- | --- | --- | --- |
| McLaren | orange, black | 13 | Dropbox, Dash, DELL Technologies, Gemini, avenga, okta, CISCO, OKX, ... |
| Red Bull Racing | navy blue, red, yellow | 11 | Mobil 1, HONDA, Red Bull, ORACLE, ROKT, 1Password, RAUCH, ... |
| Williams | blue, black, white | 12 | KOMATSU, britto, Gulf, ATLASSIAN, DURACELL, kraken, ... |

*Sample output from 2026-10-27. Gemini may read a slightly different list each time.*

The `team` column comes from each photo's metadata, not from Gemini, so a misread never puts the wrong photo next to a car. The query asks only for lists: a plain text field sometimes received the model's reasoning instead of an answer.

On the pit wall, each car in the timing tower has its photo. Hover it to see what Gemini read. The page gets the photos from the private bucket through `OBJ.GET_ACCESS_URL`, which signs a read URL for 6 hours, and credits the photographer under the table.

The photos are from the 2025 Italian Grand Prix, by Eustace Bagge on Wikimedia Commons, under CC BY 4.0. Ferrari raced a special livery at that race, so its car looks different from the one in the replay.

---

## Stop

The reservation bills while a continuous query runs. The pit wall cancels both a minute after the replay ends, if the page is still open. Otherwise press **Stop queries** on the pit wall, or run the saved query **99 Stop: cancel the continuous queries**. If you started them from the notebook, cancel them from the notebook.

---

## Key Takeaways

| Capability | Technology | Business value |
| --- | --- | --- |
| Land a stream in tables | Pub/Sub BigQuery subscriptions | Every event is queryable as it arrives |
| Spot a moment in seconds, in SQL | BigQuery continuous queries | The rule is a `WHERE` clause that an analyst can read and change |
| Aggregate over time on a stream | `TUMBLE` windows (Preview) | Trends such as a closing gap, in a 30-second SQL window |
| Make a judgement call from data | `AI.GENERATE` with Gemini | A decision in seconds, from the same query that gathers the facts |
| Query files like rows | Object tables and ObjectRef | Photos, documents or audio in Cloud Storage, read by the same SQL function |

---

## What's Next

Turn the replay into a lap-by-lap debrief, govern it in Knowledge Catalog and ask a data agent about the race: [Post-Race Debrief](02-debrief.md).

Before each experiment, predict what the pit wall will show. Then run a new replay with **Start race**.

### Flag more gap closings

In `infra/variables.tf`, line 84, in the `gap_closing_seconds` variable:

```diff
-  default     = 1
+  default     = 0.5
```

Or make the same edit from the terminal:

```bash
perl -0pi -e 's/(variable "gap_closing_seconds" \{.*?default\s+=\s+)1\n/${1}0.5\n/s' infra/variables.tf
```

Then apply:

```bash
(cd infra && tofu apply)
```

The apply renders the new threshold into the saved query and the pit wall. Expect more `GAP_CLOSING` moments and more calls. To undo, set it back to `1` and apply.

### Add a red flag moment

In `queries/03a-moments-fast.sql`, line 17, in the `CASE` that names the moment, add a rule after the pit stop:

```diff
         WHEN event_type = 'pit' THEN 'PIT_STOP'
+        WHEN event_type = 'race_control' AND JSON_VALUE(payload, '$.flag') = 'RED' THEN 'RED_FLAG'
```

In `infra/strategist.tf`, line 77, in the `CALL_MOMENTS` value, let the strategist answer it:

```diff
-        value = "SAFETY_CAR,RAIN_STARTED,GAP_CLOSING"
+        value = "SAFETY_CAR,RAIN_STARTED,GAP_CLOSING,RED_FLAG"
```

Apply as above. This race has no red flag in laps 30 to 50, so nothing new appears. Set `openf1_session_key`, the replay window and `race_name` in `infra/variables.tf` to a race that has one to see it fire.

### Replay faster

In `infra/variables.tf`, line 64, in the `replay_speed` variable:

```diff
-  default     = "5"
+  default     = "10"
```

```bash
perl -0pi -e 's/(variable "replay_speed" \{.*?default\s+=\s+)"5"/${1}"10"/s' infra/variables.tf
```

Apply as above. The window takes about half as long. The `TUMBLE` windows still close every 30 seconds of arrival time, so each one now covers 5 minutes of racing.

---

## Navigation

[← Overview](README.md) | [Post-Race Debrief →](02-debrief.md) | [Quick Reference](quick.md) | [Architecture](architecture.md)
