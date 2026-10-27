# F1 Pit Wall with Real-Time Race Strategy

Learn how a stream of events becomes a decision in seconds, with Pub/Sub, BigQuery continuous queries and Gemini.

Back to the [repository README](../README.md).

## What You'll Build

1. A replay of laps 30 to 50 of the 2025 Australian Grand Prix, published to Pub/Sub and landed in BigQuery with no code
2. Two continuous queries that flag safety cars, pit stops, rain and closing gaps as the events arrive
3. A strategist that answers each moment that matters with a Gemini call from `AI.GENERATE`
4. A private pit wall that shows the timing, the moments and the calls live
5. An object table over one photo per team, read by the same `AI.GENERATE` function

## Technologies

| Service | Purpose |
| --- | --- |
| Pub/Sub | Carries race events and moments. BigQuery subscriptions land them in tables. |
| BigQuery continuous queries | Flag the moments in SQL as the rows arrive, and publish them to Pub/Sub |
| BigQuery `AI.GENERATE` with Gemini | Turns a snapshot of the field into a strategy call, and reads the car photos |
| BigQuery object tables | Make the car photos in Cloud Storage queryable, with an ObjectRef per file |
| Cloud Run | The replayer job, the strategist and the pit wall |
| BigQuery Studio | Saved queries and notebooks for every step |
| OpenTofu | Builds all of it with one `tofu apply` |

## Results

From a replay on 2026-10-25:

- Every moment the race contains was flagged once: 2 safety cars, 31 pit stops and 1 rain start
- Safety cars, pit stops and rain reached Pub/Sub 3 to 6 seconds after the event landed in BigQuery
- 15 strategy calls, each written 4 to 10 seconds after its moment arrived

## Guides

| Guide | Covers |
| --- | --- |
| [Race Strategy](01-race-strategy.md) | Start the race, read the rules and the calls, and prove it |
| [Quick Reference](quick.md) | Copy-paste commands and queries, with sample output |
| [Architecture](architecture.md) | Pipeline overview, data flow, message formats, observed behaviour |
