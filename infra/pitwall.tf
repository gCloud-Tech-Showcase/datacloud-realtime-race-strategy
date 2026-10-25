# =============================================================================
# PIT WALL
# A private Cloud Run web app: timing tower, moments and strategy calls for one
# replay. Its Start button runs the replayer job and then starts the two
# continuous queries. Open it with:
#
#   gcloud run services proxy pitwall --region=<region> --project=<project>
#
# Only the members in pit_wall_viewers may open it. No public access is granted.
# scripts/setup.sh sets pit_wall_viewers to your gcloud account.
# =============================================================================

resource "google_service_account" "pitwall" {
  account_id   = "pitwall"
  display_name = "Pit wall"
  description  = "Reads the race tables, starts the replayer and the continuous queries"

  depends_on = [time_sleep.api_propagation]
}

resource "google_project_iam_member" "pitwall_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.pitwall.member
}

resource "google_bigquery_dataset_iam_member" "pitwall_reader" {
  for_each = toset(["raw", "serving"])

  dataset_id = google_bigquery_dataset.stages[each.key].dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = google_service_account.pitwall.member
}

# Run the replayer with a RUN_ID override.
resource "google_cloud_run_v2_job_iam_member" "pitwall_runs_replayer" {
  location = google_cloud_run_v2_job.replayer.location
  name     = google_cloud_run_v2_job.replayer.name
  role     = "roles/run.jobsExecutorWithOverrides"
  member   = google_service_account.pitwall.member
}

# Start continuous queries that run as cq-runner.
resource "google_service_account_iam_member" "pitwall_acts_as_cq_runner" {
  service_account_id = google_service_account.cq_runner.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.pitwall.member
}

resource "google_cloud_run_v2_service" "pitwall" {
  name                = "pitwall"
  location            = var.region
  deletion_protection = false
  # Reached through `gcloud run services proxy`, which calls the service URL
  # with the viewer's identity token. IAM below decides who gets in.
  ingress = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.pitwall.email
    timeout         = "150s"

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }

    containers {
      image = local.service_image["pitwall"]

      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "REGION"
        value = var.region
      }
      env {
        name  = "BQ_LOCATION"
        value = var.dataset_location
      }
      env {
        name  = "REPLAYER_JOB"
        value = google_cloud_run_v2_job.replayer.name
      }
      env {
        name  = "CQ_SERVICE_ACCOUNT"
        value = google_service_account.cq_runner.email
      }
      env {
        name  = "MOMENTS_FAST_SQL"
        value = local.rendered_queries["03a-moments-fast"]
      }
      env {
        name  = "MOMENTS_WINDOWED_SQL"
        value = local.rendered_queries["03b-moments-windowed"]
      }
    }
  }

  labels = {
    project = "datacloud-realtime-race-strategy"
    domain  = "pitwall"
  }

  depends_on = [
    terraform_data.service_image,
    time_sleep.wait_continuous_assignment,
    google_project_iam_member.pitwall_job_user,
    google_bigquery_dataset_iam_member.pitwall_reader,
    google_cloud_run_v2_job_iam_member.pitwall_runs_replayer,
    google_service_account_iam_member.pitwall_acts_as_cq_runner,
  ]
}

resource "google_cloud_run_v2_service_iam_member" "pitwall_viewers" {
  for_each = toset(var.pit_wall_viewers)

  location = google_cloud_run_v2_service.pitwall.location
  name     = google_cloud_run_v2_service.pitwall.name
  role     = "roles/run.invoker"
  member   = each.value
}
