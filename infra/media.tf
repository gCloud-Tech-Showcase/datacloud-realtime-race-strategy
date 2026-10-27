# =============================================================================
# CAR PHOTOS
# One photo per team, from Wikimedia Commons (media/car_photos.json lists them
# with their author and license). The loader downloads them into the race-data
# bucket during apply, like the race data. Nothing here touches the replay: the
# photos are read once, before any race, and the pit wall shows them next to
# each car.
#
#   bucket media/cars/*.jpg -> raw.car_photos (object table, ObjectRef `ref`)
#     -> queries/06-cars.sql (AI.GENERATE) -> serving.cars
# =============================================================================

resource "terraform_data" "car_photos" {
  triggers_replace = [
    google_storage_bucket.race_data.name,
    filesha256("${path.module}/../media/car_photos.json"),
  ]

  provisioner "local-exec" {
    command = "python3 ${path.module}/scripts/load_car_photos.py ${google_storage_bucket.race_data.name} ${path.module}/../media/car_photos.json"
  }
}

# The connection reads the files for the object table and for AI.GENERATE.
resource "google_storage_bucket_iam_member" "connection_media_reader" {
  bucket = google_storage_bucket.race_data.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_bigquery_connection.vertex_ai.cloud_resource[0].service_account_id}"

  depends_on = [time_sleep.wait_connection_sa]
}

# A new bucket grant took up to a minute before the connection could read.
resource "time_sleep" "wait_connection_media_reader" {
  create_duration = "60s"

  depends_on = [google_storage_bucket_iam_member.connection_media_reader]
}

# An object table lists the files and their metadata, live, with no cache.
resource "google_bigquery_table" "car_photos" {
  dataset_id          = google_bigquery_dataset.stages["raw"].dataset_id
  table_id            = "car_photos"
  description         = "One photo per team in the race-data bucket, with an ObjectRef in `ref`"
  deletion_protection = false

  external_data_configuration {
    autodetect      = false
    connection_id   = google_bigquery_connection.vertex_ai.name
    object_metadata = "SIMPLE"
    source_uris     = ["gs://${google_storage_bucket.race_data.name}/media/cars/*.jpg"]
  }

  depends_on = [time_sleep.wait_connection_media_reader]
}

# Runs the saved query 06 Cars once, to write serving.cars: 10 Gemini requests.
resource "terraform_data" "cars" {
  triggers_replace = [
    terraform_data.car_photos.id,
    sha256(local.rendered_queries["06-cars"]),
  ]

  provisioner "local-exec" {
    # On stdin: the SQL starts with "--", which bq would read as a flag.
    command = "printf '%s' \"$CARS_SQL\" | bq --project_id=${var.project_id} query --use_legacy_sql=false --location=${var.dataset_location} --quiet --format=none"
    environment = {
      CARS_SQL = local.rendered_queries["06-cars"]
    }
  }

  depends_on = [
    google_bigquery_table.car_photos,
    google_project_iam_member.bq_connection_vertex_ai_user,
  ]
}
