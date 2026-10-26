# F1 Pit Wall with Real-Time Race Strategy Quick Reference

Copy-paste commands and queries, with sample output. Run them from the repository root, with `PROJECT_ID` set to your project:

```bash
PROJECT_ID=<your-project-id>
```

Each query is a saved query under **BigQuery Studio > Queries**. To run one from the terminal instead, fill in the project and pipe the file to `bq`:

```bash
run_query() { perl -pe "s/\\\$\{project_id\}/$PROJECT_ID/g" "queries/$1.sql" | bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --location=US; }
```

> **Sample output only.** Values change with every run. Check the shape of the output, not the exact values.

---

## 1. Check the deployment

```bash
./scripts/verify.sh --expect READY
```

```text
Checking <project> (us-central1)
  ok    race data in the bucket
  ok    topic race-events
  ...
  ok    service strategist ready
  ok    service pitwall ready
READY
```

---

## 2. Check that a moment gets a call

Publishes a test `SAFETY_CAR` moment and waits for the strategist's call. This makes one Gemini request.

```bash
./scripts/verify.sh --smoke
```

```text
Publishing a test SAFETY_CAR moment for run run-184b04fc
Waiting for the moment in serving.moments and its call in serving.calls.
  ok    moment answered with a strategy call
SMOKE OK
```

---

## 3. Open the pit wall

```bash
gcloud run services proxy pitwall --region=us-central1 --project="$PROJECT_ID"
```

Open http://localhost:8080 and press **Start race**. **Stop** cancels the continuous queries.

---

## 4. Read a raw race event

While a replay runs, pull one message from the `-demo` subscription. Nothing else reads it.

```bash
gcloud pubsub subscriptions pull race-events-demo --project="$PROJECT_ID" --limit=1 --auto-ack \
  --format="value(message.data)" | python3 -m json.tool
```

```json
{
    "run_id": "run-184b04fc",
    "event_type": "car_data",
    "event_ts": "2025-03-16T05:31:00.161000+00:00",
    "session_key": 9693,
    "driver_number": 1,
    "payload": "{\"brake\": 100, \"date\": \"2025-03-16T05:31:00.161000+00:00\", \"driver_number\": 1, \"drs\": 1, \"meeting_key\": 1254, \"n_gear\": 2, \"rpm\": 8993, \"session_key\": 9693, \"speed\": 105, \"throttle\": 0}"
}
```

*The same event as it landed in `raw.raw_events` from a replay on 2026-10-25: car 1 braking into a slow corner.*

---

## 5. Events landed for the latest replay

Saved query **02 Events: what landed for the latest replay**:

```bash
run_query 02-raw-events
```

```text
+------------+--------+---------------------+---------------------+
| event_type | events |  latest_race_time   | latest_publish_time |
+------------+--------+---------------------+---------------------+
| car_data   | 186700 | 2025-03-16 05:50:29 | 2026-10-25 23:06:03 |
| intervals  |   7128 | 2025-03-16 05:50:29 | 2026-10-25 23:06:03 |
| laps       |    823 | 2025-03-16 05:50:27 | 2026-10-25 23:06:03 |
| ...        |        |                     |                     |
+------------+--------+---------------------+---------------------+
```

---

## 6. Moments flagged

Saved query **03c Moments: what the continuous queries flagged**:

```bash
run_query 03c-moments
```

```text
+------------+-----+--------+---------------------+---------------------+---------------------+
|   moment   | lap | driver |      race_time      |       detail        | seconds_after_event |
+------------+-----+--------+---------------------+---------------------+---------------------+
| SAFETY_CAR |  34 | NULL   | 2025-03-16 05:15:09 | SAFETY CAR DEPLOYED |                 4.0 |
| PIT_STOP   |  33 | TSU    | 2025-03-16 05:15:54 | pit lane 18.997 s   |                 3.4 |
| ...        |     |        |                     |                     |                     |
+------------+-----+--------+---------------------+---------------------+---------------------+
```

---

## 7. Strategy calls

Saved query **04b Calls: the strategist's answers**:

```bash
run_query 04b-calls
```

Each row has the moment, the lap, the car, `status` (`OK` or `FAILED`), the seconds the call took and `call_text`:

```text
GAP_CLOSING | 40 | GAS | OK | 4.0 | GAS: STAY OUT, gap to HAM closed to 0.437s, within DRS range with 7-lap-old tyres.
```

---

## 8. Prove that no moment was missed

Run it after the replay ends. Every row must say `true`. Saved query **05 Proof: flagged moments against the race**:

```bash
run_query 05-proof
```

```text
+--------------+--------------+----------+---------+------+
|    run_id    |    moment    | expected | flagged |  ok  |
+--------------+--------------+----------+---------+------+
| run-184b04fc | PIT_STOP     |       31 |      31 | true |
| run-184b04fc | RAIN_STARTED |        1 |       1 | true |
| run-184b04fc | SAFETY_CAR   |        2 |       2 | true |
+--------------+--------------+----------+---------+------+
```

---

## 9. Check the dead-letter topic

Must print nothing. A message here is an event that BigQuery rejected 5 times.

```bash
gcloud pubsub subscriptions pull race-events-dead-letter-demo --project="$PROJECT_ID" --limit=5 --format="value(message.data)"
```

---

## 10. Stop the continuous queries

The reservation bills while a continuous query runs. Saved query **99 Stop: cancel the continuous queries**:

```bash
run_query 99-stop
```

---

## Navigation

[← Overview](README.md) | [Race Strategy](01-race-strategy.md) | [Architecture](architecture.md)
