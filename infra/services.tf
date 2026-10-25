# =============================================================================
# SERVICE IMAGES
# Each directory under services/ holds one container: the replayer job, the
# strategist and the pit wall. Cloud Build builds each image as a dedicated
# service account and pushes it to Artifact Registry. The image tag is a hash of
# the source, so an apply rebuilds only the services whose code changed.
# =============================================================================

locals {
  services = toset(["replayer", "strategist", "pitwall"])

  service_source_hash = {
    for name in local.services : name => substr(sha1(join("", [
      for f in sort(fileset("${path.module}/../services/${name}", "**")) :
      filesha1("${path.module}/../services/${name}/${f}") if !strcontains(f, "__pycache__")
    ])), 0, 12)
  }

  service_image = {
    for name in local.services :
    name => "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.services.repository_id}/${name}:${local.service_source_hash[name]}"
  }
}

resource "google_artifact_registry_repository" "services" {
  repository_id = "services"
  location      = var.region
  format        = "DOCKER"
  description   = "Container images for the replayer, the strategist and the pit wall"

  labels = {
    project = "datacloud-realtime-race-strategy"
    domain  = "pitwall"
  }

  depends_on = [time_sleep.api_propagation]
}

resource "google_service_account" "service_builder" {
  account_id   = "service-builder"
  display_name = "Cloud Build identity for the service images"

  depends_on = [time_sleep.api_propagation]
}

resource "google_project_iam_member" "service_builder" {
  project = var.project_id
  role    = "roles/cloudbuild.builds.builder"
  member  = google_service_account.service_builder.member
}

resource "google_artifact_registry_repository_iam_member" "service_builder_writer" {
  location   = google_artifact_registry_repository.services.location
  repository = google_artifact_registry_repository.services.name
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.service_builder.member
}

# New IAM grants took 1 to 2 minutes before Cloud Build accepted them.
resource "time_sleep" "wait_builder_iam" {
  create_duration = "90s"

  depends_on = [
    google_project_iam_member.service_builder,
    google_artifact_registry_repository_iam_member.service_builder_writer,
  ]
}

resource "terraform_data" "service_image" {
  for_each = local.services

  triggers_replace = [local.service_image[each.key]]

  provisioner "local-exec" {
    command = join(" ", [
      "gcloud builds submit ${path.module}/../services/${each.key}",
      "--project=${var.project_id}",
      "--region=${var.region}",
      "--config=${path.module}/scripts/cloudbuild.yaml",
      "--substitutions=_IMAGE=${local.service_image[each.key]}",
      "--service-account=${google_service_account.service_builder.id}",
      "--default-buckets-behavior=regional-user-owned-bucket",
      "--quiet",
    ])
  }

  depends_on = [time_sleep.wait_builder_iam]
}
