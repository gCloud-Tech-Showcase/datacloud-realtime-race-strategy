# =============================================================================
# PUB/SUB
# race-events carries every event from the replayer. race-moments carries the
# moments the continuous queries flag. Each topic has a BigQuery subscription
# that lands it in a table, and a -demo pull subscription for reading messages
# by hand without taking them from anything else.
# =============================================================================

locals {
  # On a new project, creating a topic without a storage policy failed once
  # with an organization-policy resource-locations error, although the
  # effective policy allowed every location (verified on 2026-10-25). An
  # explicit region avoids it.
  pubsub_regions = [var.region]
}

resource "google_project_service_identity" "pubsub" {
  provider = google-beta
  service  = "pubsub.googleapis.com"

  depends_on = [time_sleep.api_propagation]
}

resource "google_pubsub_topic" "race_events" {
  name = "race-events"

  message_storage_policy {
    allowed_persistence_regions = local.pubsub_regions
  }

  depends_on = [time_sleep.api_propagation]
}

resource "google_pubsub_topic" "race_moments" {
  name = "race-moments"

  message_storage_policy {
    allowed_persistence_regions = local.pubsub_regions
  }

  depends_on = [time_sleep.api_propagation]
}

# Messages that BigQuery rejects, such as a payload sent as an object instead of
# a JSON string, end up here instead of retrying out of sight.
resource "google_pubsub_topic" "race_events_dead_letter" {
  name = "race-events-dead-letter"

  message_storage_policy {
    allowed_persistence_regions = local.pubsub_regions
  }

  depends_on = [time_sleep.api_propagation]
}

# The Pub/Sub service agent writes the BigQuery subscriptions.
resource "google_bigquery_dataset_iam_member" "pubsub_writer" {
  for_each = toset(["raw", "serving"])

  dataset_id = google_bigquery_dataset.stages[each.key].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_project_service_identity.pubsub.member
}

resource "google_pubsub_subscription" "race_events_bq" {
  name  = "race-events-bq"
  topic = google_pubsub_topic.race_events.id

  bigquery_config {
    table            = "${var.project_id}.${google_bigquery_table.raw_events.dataset_id}.${google_bigquery_table.raw_events.table_id}"
    use_table_schema = true
    write_metadata   = true
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.race_events_dead_letter.id
    max_delivery_attempts = 5
  }

  depends_on = [google_bigquery_dataset_iam_member.pubsub_writer]
}

resource "google_pubsub_subscription" "race_moments_bq" {
  name  = "race-moments-bq"
  topic = google_pubsub_topic.race_moments.id

  bigquery_config {
    table            = "${var.project_id}.${google_bigquery_table.moments.dataset_id}.${google_bigquery_table.moments.table_id}"
    use_table_schema = true
    write_metadata   = true
  }

  depends_on = [google_bigquery_dataset_iam_member.pubsub_writer]
}

# Dead-lettering needs the service agent to publish to the dead-letter topic
# and to acknowledge on the source subscription.
resource "google_pubsub_topic_iam_member" "dead_letter_publisher" {
  topic  = google_pubsub_topic.race_events_dead_letter.id
  role   = "roles/pubsub.publisher"
  member = google_project_service_identity.pubsub.member
}

resource "google_pubsub_subscription_iam_member" "dead_letter_subscriber" {
  subscription = google_pubsub_subscription.race_events_bq.id
  role         = "roles/pubsub.subscriber"
  member       = google_project_service_identity.pubsub.member
}

resource "google_pubsub_subscription" "demo" {
  for_each = {
    "race-events-demo"             = google_pubsub_topic.race_events.id
    "race-moments-demo"            = google_pubsub_topic.race_moments.id
    "race-events-dead-letter-demo" = google_pubsub_topic.race_events_dead_letter.id
  }

  name                       = each.key
  topic                      = each.value
  message_retention_duration = "3600s"
  expiration_policy {
    ttl = ""
  }
}
