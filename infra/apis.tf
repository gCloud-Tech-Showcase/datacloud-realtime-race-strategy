# =============================================================================
# ENABLED APIS
# Only the services this demo uses.
# =============================================================================

resource "google_project_service" "apis" {
  for_each = toset([
    # Bootstrap pair. scripts/setup.sh also enables them imperatively, because
    # the provider needs Cloud Resource Manager before it can manage any service.
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",

    "bigquery.googleapis.com",
    "bigqueryconnection.googleapis.com", # connection that calls Gemini from BigQuery
    "aiplatform.googleapis.com",         # Gemini, called through AI.GENERATE
    "storage.googleapis.com",            # bucket holding the downloaded race data
    "iam.googleapis.com",
    "iamcredentials.googleapis.com", # service-account impersonation

    # BigQuery Studio saved queries are stored as Dataform repositories
    # (saved_queries.tf). There is no Dataform pipeline in this demo.
    "dataform.googleapis.com",
  ])

  service = each.value

  # Disabling a service on teardown can break unrelated things in a project
  # that outlives this demo.
  disable_on_destroy = false
}

# Enabling a service returns before the service accepts calls. On a new
# project, resources created right after enablement failed with
# "API has not been used in project" or a 403 on create. Every resource that
# calls one of these services depends on this wait instead of on the service.
resource "time_sleep" "api_propagation" {
  create_duration = "90s"

  depends_on = [google_project_service.apis]
}
