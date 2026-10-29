# =============================================================================
# POST-RACE DEBRIEF
# The saved query 07 Debrief turns the JSON in raw.raw_events into one typed
# row per car per lap, serving.lap_debrief, next to the moments and calls of
# each replay. It is what the data agent and the Knowledge Catalog scans read.
#
#   raw.raw_events + serving.moments + serving.calls
#     -> queries/07-debrief.sql (one batch query) -> serving.lap_debrief
#
# The apply runs it once. Run the saved query again after a replay to add that
# replay. Because it is one BigQuery job, Dataplex records its lineage from
# the three source tables every time it runs.
# =============================================================================

resource "terraform_data" "debrief" {
  triggers_replace = [
    sha256(local.rendered_queries["07-debrief"]),
  ]

  provisioner "local-exec" {
    # On stdin: the SQL starts with "--", which bq would read as a flag.
    command = "printf '%s' \"$DEBRIEF_SQL\" | bq --project_id=${var.project_id} query --use_legacy_sql=false --location=${var.dataset_location} --quiet --format=none"
    environment = {
      DEBRIEF_SQL = local.rendered_queries["07-debrief"]
    }
  }

  # Lineage is only recorded for jobs that run after the Data Lineage API is
  # enabled, so the first run waits for it.
  depends_on = [
    time_sleep.api_propagation,
    google_bigquery_table.raw_events,
    google_bigquery_table.moments,
    google_bigquery_table.calls,
  ]
}

# Knowledge Catalog adds an entry for a new table within a minute or so. The
# glossary links and aspects attach to that entry.
resource "time_sleep" "debrief_catalog_entry" {
  create_duration = "60s"

  triggers = {
    debrief = terraform_data.debrief.id
  }
}
