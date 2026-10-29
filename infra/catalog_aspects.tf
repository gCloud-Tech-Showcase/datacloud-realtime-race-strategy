# =============================================================================
# CUSTOM ASPECTS
# Structured metadata on the serving tables, so a reader can see how a row was
# produced without reading the SQL or the service code.
#
#   moment-rules       on serving.moments            = the two continuous queries
#   model-description  on serving.calls, serving.cars = the Gemini call behind them
#
# The model description is descriptive only. It records what the model is and
# its known limits. It does not record a validation or approval status.
# =============================================================================

locals {
  gemini_model = "gemini-3.8-flash"

  moment_rules = {
    fast_rules     = "queries/03a-moments-fast.sql: one race event is enough. SAFETY_CAR from race control, PIT_STOP from a pit record, RAIN_STARTED when rainfall goes from 0 to 1."
    windowed_rules = "queries/03b-moments-windowed.sql: GAP_CLOSING when a car's interval to the car ahead shrinks by at least ${var.gap_closing_seconds} s within one ${var.window_seconds}-second TUMBLE window."
    window_time    = "TUMBLE windows close on arrival time in BigQuery (_CHANGE_TIMESTAMP), not race time. At replay speed ${var.replay_speed}, one window covers ${var.window_seconds * tonumber(var.replay_speed)} seconds of racing."
    delivery       = "Both queries publish to the race-moments topic with EXPORT DATA. The race-moments-bq subscription writes this table. A moment can appear twice after a continuous query restarts."
    observed_lag   = "Event landed to moment on Pub/Sub, replay of 2026-10-28: fast rules 0.2 to 5.8 s, windowed rule 25.5 to 73.6 s."
  }

  model_descriptions = {
    calls = {
      model        = local.gemini_model
      access       = "BigQuery AI.GENERATE through the vertex-ai-connection, thinking level LOW. The rules are a system instruction and the answer follows a responseSchema, both in model_params."
      purpose      = "Answers one moment with a strategy call: for each car that should act, BOX or STAY OUT, the tyre to fit and why."
      inputs       = "A snapshot of all 20 cars at the moment's race time (position, gap to leader, interval, tyre compound and age, last 3 lap times) and whether it is raining. queries/04-strategist-call.sql."
      outputs      = "actions (up to 5 cars, each with driver, action, tyre and reason, the action and tyre limited to known values) and call_text (the same answer as one line per car), or status FAILED with the error. latency_ms is from receiving the moment to writing the call."
      known_limits = "Grounded recommendations, not ground truth: not benchmarked against race engineers. Answers vary slightly between runs. A cold start after scale to zero took 37.6 s."
    }
    cars = {
      model        = local.gemini_model
      access       = "BigQuery AI.GENERATE over the raw.car_photos object table, with output_schema"
      purpose      = "Reads the livery colours and the sponsor names printed on one photo per team."
      inputs       = "One Wikimedia Commons photo per team (CC BY 4.0). The team name comes from the file's metadata, not from Gemini."
      outputs      = "livery_colours and sponsors, as arrays of strings. queries/06-cars.sql."
      known_limits = "Lists vary slightly between runs. Asking for car numbers returned past seasons' numbers for 3 of 10 cars, so the query does not ask."
    }
  }

  moment_rule_fields = keys(local.moment_rules)
  model_fields       = ["model", "access", "purpose", "inputs", "outputs", "known_limits"]
}

resource "google_dataplex_aspect_type" "moment_rules" {
  location       = local.catalog_location
  aspect_type_id = "moment-rules"
  display_name   = "Moment rules"
  description    = "The continuous queries that flag race moments: what each rule looks for, how its windows close and the lag observed."

  metadata_template = jsonencode({
    name = "moment_rules"
    type = "record"
    recordFields = [
      for i, field in local.moment_rule_fields : { name = field, type = "string", index = i + 1 }
    ]
  })

  depends_on = [time_sleep.api_propagation]
}

resource "google_dataplex_aspect_type" "model_description" {
  location       = local.catalog_location
  aspect_type_id = "model-description"
  display_name   = "Model description"
  description    = "The model behind a table's values: what it is, how it is called and its known limits. Descriptive only."

  metadata_template = jsonencode({
    name = "model_description"
    type = "record"
    recordFields = [
      for i, field in local.model_fields : { name = field, type = "string", index = i + 1 }
    ]
  })

  depends_on = [time_sleep.api_propagation]
}

# BigQuery entries are created by Knowledge Catalog, not by OpenTofu. On an
# @bigquery entry the provider only patches the aspects listed here, leaves
# aspects written by scans alone, and on destroy drops the entry from state
# without deleting it.
resource "google_dataplex_entry" "moment_rules" {
  project              = data.google_project.current.number
  location             = local.catalog_location
  entry_group_id       = "@bigquery"
  entry_id             = "bigquery.googleapis.com/projects/${var.project_id}/datasets/serving/tables/moments"
  entry_type           = "${local.dataplex_types}/entryTypes/bigquery-table"
  fully_qualified_name = "bigquery:${var.project_id}.serving.moments"
  parent_entry         = "${local.bigquery_entry_prefix}/bigquery.googleapis.com/projects/${var.project_id}/datasets/serving"

  aspects {
    aspect_key = "${data.google_project.current.number}.${local.catalog_location}.${google_dataplex_aspect_type.moment_rules.aspect_type_id}"
    aspect {
      data = jsonencode(local.moment_rules)
    }
  }

  depends_on = [google_bigquery_table.moments]
}

resource "google_dataplex_entry" "model" {
  for_each = local.model_descriptions

  project              = data.google_project.current.number
  location             = local.catalog_location
  entry_group_id       = "@bigquery"
  entry_id             = "bigquery.googleapis.com/projects/${var.project_id}/datasets/serving/tables/${each.key}"
  entry_type           = "${local.dataplex_types}/entryTypes/bigquery-table"
  fully_qualified_name = "bigquery:${var.project_id}.serving.${each.key}"
  parent_entry         = "${local.bigquery_entry_prefix}/bigquery.googleapis.com/projects/${var.project_id}/datasets/serving"

  aspects {
    aspect_key = "${data.google_project.current.number}.${local.catalog_location}.${google_dataplex_aspect_type.model_description.aspect_type_id}"
    aspect {
      data = jsonencode(each.value)
    }
  }

  depends_on = [
    google_bigquery_table.calls,
    terraform_data.cars,
  ]
}
