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
# Each file is a template: ${project_id} and the moment-rule settings below are
# filled in before the file is committed. The pit wall runs the same rendered
# continuous queries, so the saved query and the Start button never drift.
#
# Editing a query file and running `tofu apply` deploys the new version and
# replaces any edits made in the console.
# =============================================================================

locals {
  saved_queries = {
    for f in fileset("${path.module}/../queries", "*.sql") :
    trimsuffix(f, ".sql") => f
  }

  query_variables = {
    project_id          = var.project_id
    window_seconds      = var.window_seconds
    gap_closing_seconds = var.gap_closing_seconds
  }

  rendered_queries = {
    for name, f in local.saved_queries :
    name => templatefile("${path.module}/../queries/${f}", local.query_variables)
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
    sha256(local.rendered_queries[each.key]),
  ]

  provisioner "local-exec" {
    command = "python3 ${path.module}/scripts/commit_asset.py ${google_dataform_repository.saved_query[each.key].id} - content.sql"
    environment = {
      ASSET_CONTENT = local.rendered_queries[each.key]
    }
  }
}
