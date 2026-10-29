# =============================================================================
# TABLES
# raw_events is written by the race-events BigQuery subscription, moments by
# the race-moments BigQuery subscription, and calls by the strategist. The two
# subscriptions use the table schema, so the message fields map to columns by
# name, and the metadata columns hold the Pub/Sub message metadata.
# =============================================================================

locals {
  # Columns that a BigQuery subscription with write_metadata = true fills.
  pubsub_metadata_columns = [
    { name = "subscription_name", type = "STRING", mode = "NULLABLE", description = "Pub/Sub subscription that wrote the row" },
    { name = "message_id", type = "STRING", mode = "NULLABLE", description = "Pub/Sub message ID" },
    { name = "publish_time", type = "TIMESTAMP", mode = "NULLABLE", description = "When Pub/Sub received the message" },
    { name = "attributes", type = "JSON", mode = "NULLABLE", description = "Pub/Sub message attributes" },
  ]
}

resource "google_bigquery_table" "raw_events" {
  dataset_id          = google_bigquery_dataset.stages["raw"].dataset_id
  table_id            = "raw_events"
  description         = "Every race event the replayer publishes, one row per message"
  deletion_protection = false
  clustering          = ["run_id", "event_type"]

  time_partitioning {
    type  = "DAY"
    field = "publish_time"
  }

  schema = jsonencode(concat([
    { name = "run_id", type = "STRING", mode = "NULLABLE", description = "One replay of the race" },
    { name = "event_type", type = "STRING", mode = "NULLABLE", description = "OpenF1 stream: car_data, laps, race_control, ..." },
    { name = "event_ts", type = "TIMESTAMP", mode = "NULLABLE", description = "Race time when the event became known" },
    { name = "session_key", type = "INT64", mode = "NULLABLE", description = "OpenF1 session" },
    { name = "driver_number", type = "INT64", mode = "NULLABLE", description = "Car number, empty for race-wide events" },
    # The replayer sends payload as a JSON string. The subscription rejects a
    # nested object for a JSON column, and the message then retries until it
    # reaches the dead-letter topic.
    { name = "payload", type = "JSON", mode = "NULLABLE", description = "The OpenF1 record as published" },
  ], local.pubsub_metadata_columns))
}

resource "google_bigquery_table" "moments" {
  dataset_id          = google_bigquery_dataset.stages["serving"].dataset_id
  table_id            = "moments"
  labels              = local.insights_labels["moments"]
  description         = "Race moments flagged by the continuous queries"
  deletion_protection = false
  clustering          = ["run_id", "moment"]

  time_partitioning {
    type  = "DAY"
    field = "publish_time"
  }

  schema = jsonencode(concat([
    { name = "run_id", type = "STRING", mode = "NULLABLE", description = "One replay of the race" },
    { name = "moment", type = "STRING", mode = "NULLABLE", description = "SAFETY_CAR, PIT_STOP, RAIN_STARTED, GAP_CLOSING or CAR_STOPPED" },
    { name = "driver_number", type = "INT64", mode = "NULLABLE", description = "Car number, empty for race-wide moments" },
    { name = "lap", type = "INT64", mode = "NULLABLE", description = "Race lap of the moment, when known" },
    { name = "event_ts", type = "TIMESTAMP", mode = "NULLABLE", description = "Race time of the event that triggered the moment" },
    { name = "detail", type = "STRING", mode = "NULLABLE", description = "What the rule saw, as text" },
  ], local.pubsub_metadata_columns))
}

resource "google_bigquery_table" "calls" {
  dataset_id          = google_bigquery_dataset.stages["serving"].dataset_id
  table_id            = "calls"
  labels              = local.insights_labels["calls"]
  description         = "Strategy calls made by the strategist, one per moment"
  deletion_protection = false
  clustering          = ["run_id"]

  time_partitioning {
    type  = "DAY"
    field = "created_at"
  }

  schema = jsonencode([
    { name = "run_id", type = "STRING", mode = "NULLABLE", description = "One replay of the race" },
    { name = "moment_message_id", type = "STRING", mode = "NULLABLE", description = "Pub/Sub message ID of the moment" },
    { name = "moment", type = "STRING", mode = "NULLABLE", description = "The moment the call answers" },
    { name = "driver_number", type = "INT64", mode = "NULLABLE", description = "Car number of the moment, empty for race-wide moments" },
    { name = "lap", type = "INT64", mode = "NULLABLE", description = "Race lap of the moment" },
    { name = "event_ts", type = "TIMESTAMP", mode = "NULLABLE", description = "Race time of the moment" },
    { name = "status", type = "STRING", mode = "NULLABLE", description = "OK, or FAILED when Gemini returned an error" },
    { name = "call_text", type = "STRING", mode = "NULLABLE", description = "Gemini's strategy call, one line per car: driver, BOX or STAY OUT, the tyre, and why" },
    { name = "actions", type = "RECORD", mode = "REPEATED", description = "The same call as typed fields, from Gemini's structured output", fields = [
      { name = "driver", type = "STRING", mode = "NULLABLE", description = "Three-letter driver code" },
      { name = "action", type = "STRING", mode = "NULLABLE", description = "BOX or STAY OUT" },
      { name = "tyre", type = "STRING", mode = "NULLABLE", description = "Tyre to fit when boxing, empty when staying out" },
      { name = "reason", type = "STRING", mode = "NULLABLE", description = "Why, in under 15 words" },
    ] },
    { name = "error", type = "STRING", mode = "NULLABLE", description = "The error when status is FAILED" },
    { name = "model", type = "STRING", mode = "NULLABLE", description = "Gemini model that made the call" },
    { name = "latency_ms", type = "INT64", mode = "NULLABLE", description = "Time from receiving the moment to writing the call" },
    { name = "created_at", type = "TIMESTAMP", mode = "NULLABLE", description = "When the call was written" },
  ])
}
