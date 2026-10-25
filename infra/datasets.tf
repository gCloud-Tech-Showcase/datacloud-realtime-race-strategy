# =============================================================================
# BIGQUERY DATASETS
# One dataset per medallion STAGE (semantic names), so each stage can be shared
# independently as a Data Product later. The domain ("race_strategy") is a
# Dataform tag — never a dataset name, never a table-name prefix.
#
#   raw         = data landed as-is (object tables, loaded files)
#   processed   = cleansed / typed / flattened
#   serving     = features, models, marts, predictions — what consumers query
#   assertions  = data-quality artifacts (hard-fail assertions + warning views)
#
# Terraform owns these, not Dataform. Dataform WILL auto-create a missing
# dataset, which looks fine until `tofu destroy` leaves it orphaned, unlabeled
# and untracked. Adding a stage here is not optional.
# =============================================================================

resource "google_bigquery_dataset" "stages" {
  for_each = {
    # Delete this line if the domain has no landed raw data — e.g. when the only
    # source is an external public table referenced by a Dataform declaration.
    raw = "RAW: F1 Pit Wall: Real-Time Race Strategy source data as landed"

    processed = "PROCESSED: cleansed & typed F1 Pit Wall: Real-Time Race Strategy data"
    serving   = "SERVING: F1 Pit Wall: Real-Time Race Strategy marts, models and predictions"

    # Not a medallion stage — the shared namespace Dataform materializes both
    # hard-fail assertions and warning-level monitoring views into
    # (workflow_settings.yaml: defaultAssertionDataset).
    assertions = "QUALITY: data-quality assertions and monitoring views"
  }

  dataset_id  = each.key
  location    = var.dataset_location
  description = each.value

  # Rebuildable by design: let `tofu destroy` remove these even though Dataform
  # populates them (everything is reproducible on the next run).
  delete_contents_on_destroy = true

  labels = {
    project = "datacloud-realtime-race-strategy"
    purpose = "data-domain"
    domain  = "pitwall"
    stage   = each.key
  }

  depends_on = [time_sleep.api_propagation]
}
