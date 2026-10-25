# =============================================================================
# REPLAYER
# A Cloud Run job that replays the race from the race-data bucket to the
# race-events topic. The pit wall's Start button runs it with a new RUN_ID.
# =============================================================================

resource "google_service_account" "replayer" {
  account_id   = "replayer"
  display_name = "Race replayer"
  description  = "Reads the race data and publishes race events"

  depends_on = [time_sleep.api_propagation]
}

resource "google_storage_bucket_iam_member" "replayer_data_reader" {
  bucket = google_storage_bucket.race_data.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.replayer.member
}

resource "google_pubsub_topic_iam_member" "replayer_publisher" {
  topic  = google_pubsub_topic.race_events.id
  role   = "roles/pubsub.publisher"
  member = google_service_account.replayer.member
}

resource "google_cloud_run_v2_job" "replayer" {
  name                = "replayer"
  location            = var.region
  deletion_protection = false

  template {
    task_count = 1

    template {
      service_account = google_service_account.replayer.email
      # The window at 5x takes about 8.5 minutes. A failed replay is started
      # again from the pit wall, never retried with the same run_id.
      timeout     = "1800s"
      max_retries = 0

      containers {
        image = local.service_image["replayer"]

        env {
          name  = "PROJECT_ID"
          value = var.project_id
        }
        env {
          name  = "TOPIC"
          value = google_pubsub_topic.race_events.name
        }
        env {
          name  = "BUCKET"
          value = google_storage_bucket.race_data.name
        }
        env {
          name  = "SESSION_KEY"
          value = var.openf1_session_key
        }
        env {
          name  = "WINDOW_START"
          value = var.replay_window_start
        }
        env {
          name  = "WINDOW_END"
          value = var.replay_window_end
        }
        env {
          name  = "SPEED"
          value = var.replay_speed
        }
      }
    }
  }

  labels = {
    project = "datacloud-realtime-race-strategy"
    domain  = "pitwall"
  }

  depends_on = [
    terraform_data.service_image,
    terraform_data.race_data,
    google_storage_bucket_iam_member.replayer_data_reader,
    google_pubsub_topic_iam_member.replayer_publisher,
  ]
}
