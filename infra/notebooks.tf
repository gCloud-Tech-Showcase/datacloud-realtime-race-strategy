# =============================================================================
# BIGQUERY STUDIO NOTEBOOKS
# Every .ipynb in notebooks/ becomes a notebook under BigQuery Studio >
# Notebooks. A BigQuery Studio notebook is a Dataform repository with the label
# single-file-asset-type=notebook, holding one file, content.ipynb. OpenTofu
# creates the repository; commit_asset.py writes the file, because no
# OpenTofu resource commits files into a Dataform repository.
#
# The commit reruns whenever the notebook file changes, so editing a notebook
# and running `tofu apply` deploys the new version. That replaces any edits
# made to the notebook in the console.
# =============================================================================

locals {
  notebooks = {
    for f in fileset("${path.module}/../notebooks", "*.ipynb") :
    trimsuffix(f, ".ipynb") => f
  }
}

resource "google_dataform_repository" "notebook" {
  for_each = local.notebooks

  provider        = google-beta
  project         = var.project_id
  region          = var.region
  name            = "notebook-${each.key}"
  display_name    = title(replace(each.key, "-", " "))
  deletion_policy = "FORCE"

  labels = {
    single-file-asset-type = "notebook"
    purpose                = "data-domain"
    domain                 = "pitwall"
  }

  depends_on = [time_sleep.api_propagation]
}

resource "terraform_data" "notebook_content" {
  for_each = local.notebooks

  triggers_replace = [
    google_dataform_repository.notebook[each.key].id,
    filesha256("${path.module}/../notebooks/${each.value}"),
  ]

  provisioner "local-exec" {
    command = "python3 ${path.module}/scripts/commit_asset.py ${google_dataform_repository.notebook[each.key].id} ${path.module}/../notebooks/${each.value} content.ipynb"
  }
}
