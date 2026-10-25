# =============================================================================
# BIGQUERY STUDIO SAVED QUERIES
# Every .sql in queries/ becomes a saved query under BigQuery Studio > Queries.
# A saved query is a Dataform repository with the label
# single-file-asset-type=sql, holding one file, content.sql. OpenTofu creates
# the repository; commit_asset.py writes the file, the same way notebooks.tf
# deploys notebooks.
#
# The first line of each file is "-- <display name>", for example
# "-- 02 Data: portfolio by desk". Number the files like the guide: 00 for
# checks, the step number for each step, 99 for reset.
#
# Editing a query file and running `tofu apply` deploys the new version and
# replaces any edits made in the console.
# =============================================================================

locals {
  saved_queries = {
    for f in fileset("${path.module}/../queries", "*.sql") :
    trimsuffix(f, ".sql") => f
  }
}

resource "google_dataform_repository" "saved_query" {
  for_each = local.saved_queries

  provider        = google-beta
  project         = var.project_id
  region          = var.region
  name            = "query-${each.key}"
  display_name    = trimspace(trimprefix(split("\n", file("${path.module}/../queries/${each.value}"))[0], "--"))
  deletion_policy = "FORCE"

  labels = {
    single-file-asset-type = "sql"
    purpose                = "data-domain"
    domain                 = "pitwall"
  }

  lifecycle {
    precondition {
      condition     = startswith(file("${path.module}/../queries/${each.value}"), "-- ")
      error_message = "queries/${each.value} must start with a \"-- <display name>\" line."
    }
  }

  depends_on = [time_sleep.api_propagation]
}

resource "terraform_data" "saved_query_content" {
  for_each = local.saved_queries

  triggers_replace = [
    google_dataform_repository.saved_query[each.key].id,
    filesha256("${path.module}/../queries/${each.value}"),
  ]

  provisioner "local-exec" {
    command = "python3 ${path.module}/scripts/commit_asset.py ${google_dataform_repository.saved_query[each.key].id} ${path.module}/../queries/${each.value} content.sql"
  }
}
