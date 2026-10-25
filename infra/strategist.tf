# =============================================================================
# STRATEGIST
# A Cloud Run service that receives every race moment as a Pub/Sub push, runs
# queries/04-strategist-call.sql (a field snapshot plus AI.GENERATE) and writes
# the call to serving.calls.
# =============================================================================

resource "google_service_account" "strategist" {
  account_id   = "strategist"
  display_name = "Strategist"
  description  = "Snapshots the field, calls Gemini through BigQuery and writes the call"

  depends_on = [time_sleep.api_propagation]
}

resource "google_project_iam_member" "strategist_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.strategist.member
}

resource "google_bigquery_dataset_iam_member" "strategist_raw_reader" {
  dataset_id = google_bigquery_dataset.stages["raw"].dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = google_service_account.strategist.member
}

resource "google_bigquery_dataset_iam_member" "strategist_serving_writer" {
  dataset_id = google_bigquery_dataset.stages["serving"].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_service_account.strategist.member
}

resource "google_bigquery_connection_iam_member" "strategist_connection_user" {
  location      = google_bigquery_connection.vertex_ai.location
  connection_id = google_bigquery_connection.vertex_ai.connection_id
  role          = "roles/bigquery.connectionUser"
  member        = google_service_account.strategist.member
}

resource "google_cloud_run_v2_service" "strategist" {
  name                = "strategist"
  location            = var.region
  deletion_protection = false
  # Pub/Sub pushes from this project count as internal traffic.
  ingress = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    service_account = google_service_account.strategist.email
    timeout         = "90s"

    # One instance, one request at a time (see the Dockerfile): a moment
    # delivered twice is answered once.
    max_instance_request_concurrency = 1
    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }

    containers {
      image = local.service_image["strategist"]

      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "CALLS_TABLE"
        value = "${var.project_id}.${google_bigquery_table.calls.dataset_id}.${google_bigquery_table.calls.table_id}"
      }
      env {
        name  = "MODEL"
        value = "gemini-3.8-flash"
      }
      env {
        name  = "STRATEGIST_SQL"
        value = local.rendered_queries["04-strategist-call"]
      }
    }
  }

  labels = {
    project = "datacloud-realtime-race-strategy"
    domain  = "pitwall"
  }

  depends_on = [
    terraform_data.service_image,
    google_project_iam_member.strategist_job_user,
    google_bigquery_dataset_iam_member.strategist_raw_reader,
    google_bigquery_dataset_iam_member.strategist_serving_writer,
    google_bigquery_connection_iam_member.strategist_connection_user,
  ]
}

# The identity Pub/Sub uses to push moments to the strategist.
resource "google_service_account" "moments_push" {
  account_id   = "moments-push"
  display_name = "Pub/Sub push identity for race moments"

  depends_on = [time_sleep.api_propagation]
}

resource "google_cloud_run_v2_service_iam_member" "strategist_invoker" {
  location = google_cloud_run_v2_service.strategist.location
  name     = google_cloud_run_v2_service.strategist.name
  role     = "roles/run.invoker"
  member   = google_service_account.moments_push.member
}

# Pub/Sub signs the push with a token for moments-push.
resource "google_service_account_iam_member" "pubsub_signs_moments_push" {
  service_account_id = google_service_account.moments_push.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = google_project_service_identity.pubsub.member
}

resource "google_pubsub_subscription" "race_moments_strategist" {
  name                 = "race-moments-strategist"
  topic                = google_pubsub_topic.race_moments.id
  ack_deadline_seconds = 90

  push_config {
    push_endpoint = google_cloud_run_v2_service.strategist.uri

    oidc_token {
      service_account_email = google_service_account.moments_push.email
    }
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "60s"
  }

  depends_on = [
    google_cloud_run_v2_service_iam_member.strategist_invoker,
    google_service_account_iam_member.pubsub_signs_moments_push,
  ]
}
