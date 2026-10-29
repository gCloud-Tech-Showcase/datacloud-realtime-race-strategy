# =============================================================================
# DATA PROFILE, QUALITY AND INSIGHTS SCANS
# Knowledge Catalog scans on the data product tables, each run once on apply.
# Results are published to the catalog, so they show on the table's Data
# profile, Data quality and Insights tabs in BigQuery, and on the data product.
#
#   raw.raw_events       profile, quality
#   serving.moments      profile, quality, insights
#   serving.calls        profile, quality, insights
#   serving.lap_debrief  profile, quality, insights
#
# Every rule passes on clean replays except gap-to-leader-is-a-number on
# raw_events, which fails on purpose to show what a failing rule looks like.
#
# The saved query 05 Proof checks one replay after it ends. A quality scan
# checks every replay in the table and keeps a pass or fail record per rule,
# by dimension, that anyone reading the table can see.
#
# The scans run on demand only. Run them again after a replay, from the table's
# Data quality tab or with `gcloud dataplex datascans run`.
# =============================================================================

locals {
  moments_table = "`${var.project_id}.serving.moments`"
  events_table  = "`${var.project_id}.raw.raw_events`"

  scan_kinds = {
    raw_events  = ["profile", "quality"]
    moments     = ["profile", "quality", "insights"]
    calls       = ["profile", "quality", "insights"]
    lap_debrief = ["profile", "quality", "insights"]
  }

  # One list of rules per table. Each rule has a kind:
  #   non_null, unique  column checks
  #   range, set        column value checks
  #   row               a SQL condition every row must meet
  #   table             a SQL condition on the whole table, usually an aggregate
  #   sql               a query that returns the failing rows. ${data()} is the table.
  quality_rules = {
    raw_events = [
      { name = "run-id-present", dimension = "COMPLETENESS", kind = "non_null", column = "run_id" },
      # A JSON column cannot take a non-null expectation, so this is a row condition.
      { name = "payload-present", dimension = "COMPLETENESS", kind = "row", sql = "payload IS NOT NULL" },
      { name = "event-type-is-openf1", dimension = "VALIDITY", kind = "set", column = "event_type", values = [
        "car_data", "intervals", "laps", "position", "overtakes", "stints", "race_control", "weather", "pit", "drivers",
      ] },
      { name = "twenty-drivers-per-replay", dimension = "COMPLETENESS", kind = "sql", sql = "SELECT run_id FROM $${data()} WHERE event_type = 'drivers' GROUP BY run_id HAVING COUNT(DISTINCT driver_number) != 20" },
      # FAILS ON PURPOSE, to show a failing rule. OpenF1 sends gap_to_leader as
      # text such as "+1 LAP" for a lapped car, about 12% of interval records
      # (seen on 2026-10-29). This rule expects a number every time and lists
      # the records that break it. That is why lap_debrief.gap_to_leader_s is
      # empty for lapped cars.
      { name = "gap-to-leader-is-a-number", dimension = "VALIDITY", kind = "sql", sql = "SELECT run_id, event_ts, driver_number, JSON_VALUE(payload, '$.gap_to_leader') AS gap_to_leader FROM $${data()} WHERE event_type = 'intervals' AND SAFE_CAST(JSON_VALUE(payload, '$.gap_to_leader') AS FLOAT64) IS NULL" },
      # The same check, accepting the known quirk: it passes while at least 85%
      # of interval records carry a number, and fails if that share drops.
      { name = "gap-to-leader-mostly-numbers", dimension = "VALIDITY", kind = "table", sql = "SAFE_DIVIDE(COUNTIF(event_type = 'intervals' AND SAFE_CAST(JSON_VALUE(payload, '$.gap_to_leader') AS FLOAT64) IS NOT NULL), COUNTIF(event_type = 'intervals')) >= 0.85" },
    ]
    moments = [
      { name = "run-id-present", dimension = "COMPLETENESS", kind = "non_null", column = "run_id" },
      { name = "moment-is-known", dimension = "VALIDITY", kind = "set", column = "moment", values = [
        "SAFETY_CAR", "PIT_STOP", "RAIN_STARTED", "GAP_CLOSING", "CAR_STOPPED",
      ] },
      { name = "car-moments-name-a-car", dimension = "VALIDITY", kind = "row", sql = "moment NOT IN ('PIT_STOP', 'GAP_CLOSING') OR driver_number IS NOT NULL" },
      # 05 Proof as a rule, for every replay that has moments: each pit stop in
      # the raw events was flagged once. Pub/Sub can deliver a message twice, so
      # each pit record counts once.
      { name = "every-pit-stop-flagged", dimension = "CONSISTENCY", kind = "sql", sql = <<-EOT
          SELECT e.run_id
          FROM (SELECT run_id, COUNT(DISTINCT TO_JSON_STRING(STRUCT(driver_number, event_ts))) AS pits FROM ${local.events_table} WHERE event_type = 'pit' GROUP BY run_id) AS e
          JOIN (
            SELECT run_id, COUNT(DISTINCT IF(moment = 'PIT_STOP', TO_JSON_STRING(STRUCT(driver_number, event_ts)), NULL)) AS flagged
            FROM $${data()} GROUP BY run_id
          ) AS m USING (run_id)
          WHERE e.pits != m.flagged
        EOT
      },
    ]
    calls = [
      { name = "status-is-known", dimension = "VALIDITY", kind = "set", column = "status", values = ["OK", "FAILED"] },
      { name = "calls-succeed", dimension = "VALIDITY", kind = "row", sql = "status = 'OK'" },
      { name = "text-when-ok", dimension = "COMPLETENESS", kind = "row", sql = "status != 'OK' OR call_text IS NOT NULL" },
      { name = "latency-is-positive", dimension = "VALIDITY", kind = "row", sql = "latency_ms > 0" },
      { name = "one-call-per-moment", dimension = "UNIQUENESS", kind = "unique", column = "moment_message_id" },
      { name = "every-call-answers-a-moment", dimension = "CONSISTENCY", kind = "sql", sql = "SELECT moment_message_id FROM $${data()} WHERE moment_message_id NOT IN (SELECT message_id FROM ${local.moments_table} WHERE message_id IS NOT NULL)" },
    ]
    lap_debrief = [
      { name = "one-row-per-car-per-lap", dimension = "UNIQUENESS", kind = "sql", sql = "SELECT run_id, driver_number, lap FROM $${data()} GROUP BY run_id, driver_number, lap HAVING COUNT(*) > 1" },
      { name = "driver-named", dimension = "COMPLETENESS", kind = "non_null", column = "driver" },
      # Laps from before the window come from history, which has fewer
      # position records, so a share of early laps has no position.
      { name = "position-known", dimension = "COMPLETENESS", kind = "non_null", column = "position", threshold = 0.8 },
      { name = "lap-time-plausible", dimension = "VALIDITY", kind = "range", column = "lap_s", min = "60", max = "300" },
      { name = "compound-is-known", dimension = "VALIDITY", kind = "set", column = "compound", values = ["SOFT", "MEDIUM", "HARD", "INTERMEDIATE", "WET"] },
      { name = "tyre-age-not-negative", dimension = "VALIDITY", kind = "row", sql = "tyre_age_laps >= 0" },
      { name = "pit-stop-has-lane-time", dimension = "VALIDITY", kind = "row", sql = "NOT pitted OR pit_lane_s > 0" },
    ]
  }

  scans = merge([
    for table, kinds in local.scan_kinds : {
      for kind in kinds : "${replace(table, "_", "-")}-${kind}" => {
        table   = table
        dataset = local.product_assets[table].dataset
        kind    = kind
      }
    }
  ]...)

  # The Insights tab needs these labels on the table. tables.tf sets them on
  # the tables OpenTofu owns. queries/07-debrief.sql sets them on
  # serving.lap_debrief, because it rebuilds the table on every run.
  insights_labels = {
    for table, kinds in local.scan_kinds : table => {
      "dataplex-data-documentation-published-scan"     = "${replace(table, "_", "-")}-insights"
      "dataplex-data-documentation-published-project"  = var.project_id
      "dataplex-data-documentation-published-location" = var.region
    } if contains(kinds, "insights")
  }
}

resource "google_project_service_identity" "dataplex" {
  provider = google-beta
  project  = var.project_id
  service  = "dataplex.googleapis.com"

  depends_on = [time_sleep.api_propagation]
}

resource "google_service_account" "data_scanner" {
  account_id   = "data-scanner"
  display_name = "Identity the profile, quality and insights scans run as"

  depends_on = [time_sleep.api_propagation]
}

resource "google_project_iam_member" "data_scanner_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.data_scanner.member
}

resource "google_bigquery_dataset_iam_member" "data_scanner_viewer" {
  for_each = toset(["raw", "serving"])

  dataset_id = google_bigquery_dataset.stages[each.key].dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = google_service_account.data_scanner.member
}

# Scans with a custom identity run as the Dataplex service agent impersonating
# that identity.
resource "google_service_account_iam_member" "dataplex_impersonates_scanner" {
  service_account_id = google_service_account.data_scanner.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = google_project_service_identity.dataplex.member
}

# Profile and quality scans can fail with an impersonation error for a minute
# or more after the grant.
resource "time_sleep" "scanner_iam_propagation" {
  create_duration = "3m"

  depends_on = [
    google_service_account_iam_member.dataplex_impersonates_scanner,
    google_project_iam_member.data_scanner_job_user,
    google_bigquery_dataset_iam_member.data_scanner_viewer,
  ]
}

resource "google_dataplex_datascan" "scan" {
  for_each = local.scans

  location     = var.region
  data_scan_id = each.key
  display_name = "${each.value.dataset}.${each.value.table} ${each.value.kind}"

  data {
    resource = "//bigquery.googleapis.com/projects/${var.project_id}/datasets/${each.value.dataset}/tables/${each.value.table}"
  }

  execution_spec {
    trigger {
      on_demand {}
    }
  }

  execution_identity {
    service_account {
      email = google_service_account.data_scanner.email
    }
  }

  dynamic "data_profile_spec" {
    for_each = each.value.kind == "profile" ? [1] : []
    content {
      catalog_publishing_enabled = true
    }
  }

  dynamic "data_quality_spec" {
    for_each = each.value.kind == "quality" ? [1] : []
    content {
      catalog_publishing_enabled = true

      dynamic "rules" {
        for_each = local.quality_rules[each.value.table]
        content {
          name        = rules.value.name
          dimension   = rules.value.dimension
          column      = try(rules.value.column, null)
          threshold   = try(rules.value.threshold, null)
          ignore_null = contains(["range", "set"], rules.value.kind) ? true : null

          dynamic "non_null_expectation" {
            for_each = rules.value.kind == "non_null" ? [1] : []
            content {}
          }

          dynamic "uniqueness_expectation" {
            for_each = rules.value.kind == "unique" ? [1] : []
            content {}
          }

          dynamic "range_expectation" {
            for_each = rules.value.kind == "range" ? [1] : []
            content {
              min_value = rules.value.min
              max_value = rules.value.max
            }
          }

          dynamic "set_expectation" {
            for_each = rules.value.kind == "set" ? [1] : []
            content {
              values = rules.value.values
            }
          }

          dynamic "row_condition_expectation" {
            for_each = rules.value.kind == "row" ? [1] : []
            content {
              sql_expression = rules.value.sql
            }
          }

          dynamic "table_condition_expectation" {
            for_each = rules.value.kind == "table" ? [1] : []
            content {
              sql_expression = rules.value.sql
            }
          }

          dynamic "sql_assertion" {
            for_each = rules.value.kind == "sql" ? [1] : []
            content {
              sql_statement = rules.value.sql
            }
          }
        }
      }
    }
  }

  dynamic "data_documentation_spec" {
    for_each = each.value.kind == "insights" ? [1] : []
    content {
      catalog_publishing_enabled = true
    }
  }

  labels = { domain = "pitwall" }

  # Creating a scan took more than 5 minutes for some tables (seen on
  # 2026-10-29), longer than the provider's default.
  timeouts {
    create = "20m"
  }

  depends_on = [
    terraform_data.debrief,
    time_sleep.scanner_iam_propagation,
  ]
}

# Starts the first run, so results are in the catalog when the apply finishes.
# Insights run after the profiles, because Gemini grounds its descriptions in
# profile results when they exist.
resource "terraform_data" "first_scan_run" {
  for_each = { for k, v in local.scans : k => v if v.kind != "insights" }

  triggers_replace = [google_dataplex_datascan.scan[each.key].id]

  provisioner "local-exec" {
    command = "gcloud dataplex datascans run ${each.key} --location=${var.region} --project=${var.project_id} --format=none"
  }
}

resource "time_sleep" "profile_results" {
  create_duration = "3m"

  depends_on = [terraform_data.first_scan_run]
}

resource "terraform_data" "first_insights_run" {
  for_each = { for k, v in local.scans : k => v if v.kind == "insights" }

  triggers_replace = [google_dataplex_datascan.scan[each.key].id]

  provisioner "local-exec" {
    command = "gcloud dataplex datascans run ${each.key} --location=${var.region} --project=${var.project_id} --format=none"
  }

  depends_on = [time_sleep.profile_results]
}
