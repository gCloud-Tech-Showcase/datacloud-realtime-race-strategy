# =============================================================================
# BIGQUERY DATASETS
# One dataset per stage. Table names carry no stage prefix: the dataset says it.
#
#   raw      = every race event as it arrives from Pub/Sub (raw_events)
#   serving  = what the pit wall reads: the moments the continuous queries
#              flag and the calls the strategist makes
# =============================================================================

resource "google_bigquery_dataset" "stages" {
  for_each = {
    raw     = "RAW: race events as they arrive from Pub/Sub"
    serving = "SERVING: race moments and strategy calls that the pit wall reads"
  }

  dataset_id  = each.key
  location    = var.dataset_location
  description = each.value

  # Every table is rebuilt by the next replay, so `tofu destroy` may remove them.
  delete_contents_on_destroy = true

  labels = {
    project = "datacloud-realtime-race-strategy"
    purpose = "data-domain"
    domain  = "pitwall"
    stage   = each.key
  }

  depends_on = [time_sleep.api_propagation]
}
