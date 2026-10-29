# datacloud-realtime-race-strategy

Standalone demo: F1 Pit Wall with Real-Time Race Strategy. A Cloud Run job replays laps 30 to 50 of the 2025 Australian Grand Prix from OpenF1 to Pub/Sub. A BigQuery subscription lands every event in `raw.raw_events`. Two continuous queries publish race moments to Pub/Sub. A Cloud Run strategist answers each safety car, rain start and gap closing with a Gemini call from `AI.GENERATE`, and a private Cloud Run pit wall shows it all. After the race, a batch query builds a lap-by-lap debrief, which Knowledge Catalog governs (data products, scans, glossary, lineage) and a Conversational Analytics agent answers questions about.

## Standing it up

```bash
./infra/scripts/setup.sh   # APIs, versioned state bucket, pit wall viewer, tofu init
cd infra && tofu apply     # zero required variables
./scripts/verify.sh --expect READY
```

**Tofu layout: flat.** Everything is in `infra/*.tf`, with one apply and no `bootstrap/` stage.

**No Dataform pipeline.** This is the event-driven variant of the domain template. The Dataform API stays, because BigQuery Studio notebooks and saved queries are Dataform repositories.

**One project ID.** `project_id`'s default in `infra/variables.tf` drives the providers, the resources, the bucket names and `setup.sh`. Never hardcode it in `.tf` files or scripts. In commands, use a `PROJECT_ID` shell variable. In `queries/*.sql`, use `${project_id}`, which the apply fills in.

**Times are UTC.** Race times (`event_ts`) are 2025-03-16. Publish times are when the replay ran.

## Words

Use these terms consistently in code, docs and commit messages.

| Term | Meaning |
| --- | --- |
| reader | The person who runs the demo in their own project |
| replay | One run of the `replayer` job, identified by `run_id` |
| race event | One OpenF1 record, published to `race-events` and landed in `raw.raw_events` |
| race time | `event_ts`: when the record became known during the race |
| window | The replayed part of the race, laps 30 to 50 (`replay_window_start`, `replay_window_end`) |
| moment | A row in `serving.moments`: `SAFETY_CAR`, `PIT_STOP`, `RAIN_STARTED` or `GAP_CLOSING` |
| fast rules | `queries/03a-moments-fast.sql`: moments from one event |
| windowed rules | `queries/03b-moments-windowed.sql`: moments from a `TUMBLE` window |
| call | A row in `serving.calls`: Gemini's answer to one moment |
| strategist | The Cloud Run service that makes the calls |
| pit wall | The Cloud Run web app the reader opens |
| debrief | `serving.lap_debrief`: one row per car per completed lap, for every replay, built by `queries/07-debrief.sql` |
| data product | A Knowledge Catalog data product: `Race Telemetry` (raw) or `Race Strategy` (serving) |
| data agent | The Conversational Analytics agent `Pit wall race engineer` (`infra/agent.tf`) |

## Data model

The full resource list is in [`README.md`](README.md#what-gets-created).

| Dataset | Object | What |
| --- | --- | --- |
| `raw` | `raw_events` | Every race event, written by the `race-events-bq` subscription (`infra/tables.tf`) |
| `serving` | `moments` | Every moment, written by the `race-moments-bq` subscription. A moment can appear twice after a continuous query restarts. |
| `serving` | `calls` | One row per answered moment, written by the strategist. `status` is `OK` or `FAILED`. |
| `raw` | `car_photos` | Object table over `media/cars/*.jpg` in the race-data bucket (`infra/media.tf`). Custom metadata on each file holds the team and the credit. |
| `serving` | `cars` | What Gemini read in each car photo, written once by the saved query `06 Cars` during the apply |
| `serving` | `lap_debrief` | One row per car per lap, for every replay, rebuilt by the saved query `07 Debrief` (`infra/debrief.tf` runs it once). Typed columns from `raw_events`, plus the car's moments and calls. |

Knowledge Catalog metadata for these tables lives in location `us`, the datasets' multi-region: data products, glossary, aspects and entry links. The scans and the saved queries are in `us-central1`.

The services are in `services/<name>/`, each with a `Dockerfile`. `infra/services.tf` builds them in Cloud Build, tagged with a hash of the source.

## Verifying

```bash
cd infra && tofu fmt -recursive && tofu validate && tofu plan
ruff format --line-length 100 services/ notebooks/ infra/scripts/ && ruff check --line-length 100 services/ notebooks/ infra/scripts/
bash -n scripts/*.sh infra/scripts/*.sh
```

There are no unit tests. After an apply:

```bash
./scripts/verify.sh --expect READY   # every resource exists and is ready
./scripts/verify.sh --smoke          # a test moment gets a call (one Gemini request)
```

After a full replay, the saved query `05 Proof: flagged moments against the race` must return `ok = true` on every row.

## Gotchas

Each line is a guardrail. The reasons are in comments next to the code. The observed behaviour behind them is in [`docs/architecture.md`](docs/architecture.md#observed-behaviour).

- **Start continuous queries only while events are landing,** and start them 10 minutes back (`CURRENT_TIMESTAMP() - INTERVAL 10 MINUTE`). On an idle table, or with a shorter lookback, they fail with "Invalid timestamp bounds".
- **Never join two `TUMBLE` aggregations with `UNION ALL`** in one continuous query. It emits nothing.
- **Send `payload` as a JSON string,** never a nested object. The BigQuery subscription rejects an object for a `JSON` column, and the message goes to `race-events-dead-letter`.
- **Never publish a record before it was known.** A lap publishes when it ends, and a stint without `lap_end`. The replayer adds `previous_rainfall` to weather records.
- **Answer each moment once.** Pub/Sub redelivers, and the 10-minute lookback can flag a moment twice. The strategist checks `serving.calls` first and runs one request at a time.
- **Keep the strategist's variables marker** (`-- (the strategist service sets the five variables here)`) in `queries/04-strategist-call.sql`. The service inserts its `SET` statements there.
- **Match car photos by the `team` in their metadata,** never by what Gemini reads. Ask Gemini for lists only: a plain text field sometimes received its reasoning, and car numbers came from past seasons.
- **Credit every car photo.** Add new photos to `media/car_photos.json` with author, license and source, and keep the pit wall's credits line. Use only CC BY or public domain photos.
- **Write `thinkingLevel` in uppercase** in `model_params` (`"LOW"`). Lowercase is rejected.
- **Each query in a guide has a saved query.** `queries/<NN>-<name>.sql` matches the block in step NN (`00` for checks, `99` for stop). Its first line is `-- <display name>`. Change the guide and the file in the same commit.
- **Each reader-facing script and step guide has a notebook twin.** `scripts/verify.sh` pairs with `notebooks/verify.ipynb`, `docs/01-race-strategy.md` with `notebooks/01-race-strategy.ipynb`, and `docs/02-debrief.md` with `notebooks/02-debrief.ipynb`. The notebooks copy the SQL of the saved queries, because a notebook cannot read the repo. Change all three in the same commit.
- **Keep the guide's line numbers in step with the files.** `docs/01-race-strategy.md` and `README.md` point at lines in `infra/variables.tf`, `infra/strategist.tf` and `queries/03a-moments-fast.sql`.
- **Put Knowledge Catalog resources for BigQuery tables in `local.catalog_location`** (`us`), never `var.region`. BigQuery entries live in the dataset's location, and `us-central1` returns 403 for them.
- **Set the Insights labels inside `queries/07-debrief.sql`.** `CREATE OR REPLACE TABLE` drops labels, and the Insights tab needs the `dataplex-data-documentation-published-*` labels on the table.
- **Leave `gap-to-leader-is-a-number` failing.** It fails on purpose, to show a failing quality rule, on OpenF1's `+1 LAP` text in a numeric field. Every other rule passes on clean replays, so a new failure is a real problem.
- **Add a new moment to the `moment-is-known` quality rule** in `infra/data_scans.tf`, or its scan fails.
- **Find the data agent by its display name.** Any edit to `infra/agent.tf` creates a new agent under a new ID, because the provider cannot update one in place.
- **Record the retirement date next to the Gemini model ID** in `queries/04-strategist-call.sql`. The migration is tracked in [#2](https://github.com/gCloud-Tech-Showcase/datacloud-realtime-race-strategy/issues/2).

## Teardown

```bash
# Stop the continuous queries first: the pit wall's Stop queries button, or the saved query 99 Stop.
cd infra && tofu destroy
```

## More

- [`README.md`](README.md): what the demo does and how to run it
- [`docs/01-race-strategy.md`](docs/01-race-strategy.md): the step-by-step guide
- [`docs/02-debrief.md`](docs/02-debrief.md): the post-race debrief, Knowledge Catalog and the data agent
- [`docs/architecture.md`](docs/architecture.md): wiring, message formats and observed behaviour
