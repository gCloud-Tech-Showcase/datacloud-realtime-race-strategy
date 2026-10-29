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
    "bigqueryreservation.googleapis.com", # Enterprise reservation for continuous queries
    "bigqueryconnection.googleapis.com",  # connection that calls Gemini from BigQuery
    "aiplatform.googleapis.com",          # Gemini, called through AI.GENERATE
    "pubsub.googleapis.com",
    "run.googleapis.com",              # replayer job, strategist, pit wall
    "artifactregistry.googleapis.com", # their container images
    "cloudbuild.googleapis.com",       # builds the images during apply
    "storage.googleapis.com",          # bucket holding the downloaded race data
    "iam.googleapis.com",
    "iamcredentials.googleapis.com", # service-account impersonation

    # BigQuery Studio notebooks and saved queries are stored as Dataform
    # repositories (notebooks.tf, saved_queries.tf). There is no Dataform
    # pipeline in this demo.
    "dataform.googleapis.com",

    # BigQuery Studio notebooks (notebooks.tf, notebook_runtime.tf). Without
    # these the console shows an Enable APIs prompt on every notebook.
    "compute.googleapis.com",          # Colab Enterprise runtime and its network
    "cloudaicompanion.googleapis.com", # Gemini in BigQuery, including the notebook assistant

    # The post-race debrief (debrief.tf, data_products.tf, data_scans.tf,
    # catalog_*.tf, agent.tf).
    "dataplex.googleapis.com",            # Knowledge Catalog: data products, scans, glossary, aspects
    "datalineage.googleapis.com",         # lineage of BigQuery jobs, from the moment it is enabled
    "geminidataanalytics.googleapis.com", # Conversational Analytics data agent
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

  # A time_sleep waits only when it is created. Recreate it when the API list
  # changes, so an API added later gets the same wait.
  triggers = {
    apis = join(",", sort(keys(google_project_service.apis)))
  }

  depends_on = [google_project_service.apis]
}
