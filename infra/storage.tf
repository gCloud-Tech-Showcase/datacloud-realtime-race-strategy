# =============================================================================
# STORAGE AND THE BIGQUERY -> GEMINI CONNECTION
# The bucket holds the race data that the loader downloads from OpenF1 during
# apply. The replayer reads it from there. The connection lets AI.GENERATE call
# Gemini from a BigQuery query.
# =============================================================================

resource "google_storage_bucket" "race_data" {
  name     = "${var.project_id}-race-data"
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # The data is downloaded again on the next apply, so `tofu destroy` may remove it.
  force_destroy = true

  labels = {
    project = "datacloud-realtime-race-strategy"
    purpose = "race-data"
    domain  = "pitwall"
  }

  depends_on = [time_sleep.api_propagation]
}

# Cloud-resource connection: it holds a Google-managed service account that
# calls Gemini on behalf of the query.
resource "google_bigquery_connection" "vertex_ai" {
  connection_id = "vertex-ai-connection"
  location      = var.dataset_location
  friendly_name = "Vertex AI Connection for Gemini"
  description   = "BigQuery connection that AI.GENERATE uses to call Gemini"

  cloud_resource {}

  depends_on = [time_sleep.api_propagation]
}

# Google creates the connection's service account asynchronously after the
# connection returns, so an immediate grant can fail with "service account does
# not exist" on a fresh apply.
resource "time_sleep" "wait_connection_sa" {
  create_duration = "30s"

  depends_on = [google_bigquery_connection.vertex_ai]
}

resource "google_project_iam_member" "bq_connection_vertex_ai_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_bigquery_connection.vertex_ai.cloud_resource[0].service_account_id}"

  depends_on = [time_sleep.wait_connection_sa]
}
