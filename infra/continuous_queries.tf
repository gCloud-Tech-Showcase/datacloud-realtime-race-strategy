# =============================================================================
# CONTINUOUS QUERIES: CAPACITY AND IDENTITY
# A continuous query runs only on an Enterprise reservation with a CONTINUOUS
# assignment. This one has no baseline and autoscales, so it bills only while
# a continuous query runs. The pit wall's Start button starts the queries, and
# Stop cancels them.
# =============================================================================

resource "google_bigquery_reservation" "continuous" {
  name              = "continuous-queries"
  location          = var.dataset_location
  edition           = "ENTERPRISE"
  slot_capacity     = 0
  ignore_idle_slots = false

  autoscale {
    max_slots = 50
  }

  depends_on = [time_sleep.api_propagation]
}

resource "google_bigquery_reservation_assignment" "continuous" {
  assignee    = "projects/${var.project_id}"
  job_type    = "CONTINUOUS"
  reservation = google_bigquery_reservation.continuous.id
}

# A new CONTINUOUS assignment took about a minute before a continuous query
# accepted it (verified on 2026-10-25). Before that, the query fails with
# "No such reservation was found".
resource "time_sleep" "wait_continuous_assignment" {
  create_duration = "90s"

  depends_on = [google_bigquery_reservation_assignment.continuous]
}

# A continuous query that exports to Pub/Sub must run as a service account.
resource "google_service_account" "cq_runner" {
  account_id   = "cq-runner"
  display_name = "Continuous query runner"
  description  = "Identity of the continuous queries that flag race moments"

  depends_on = [time_sleep.api_propagation]
}

resource "google_bigquery_dataset_iam_member" "cq_runner_raw_reader" {
  dataset_id = google_bigquery_dataset.stages["raw"].dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = google_service_account.cq_runner.member
}

resource "google_project_iam_member" "cq_runner_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.cq_runner.member
}

resource "google_pubsub_topic_iam_member" "cq_runner_moments" {
  for_each = toset(["roles/pubsub.publisher", "roles/pubsub.viewer"])

  topic  = google_pubsub_topic.race_moments.id
  role   = each.value
  member = google_service_account.cq_runner.member
}
