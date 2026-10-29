# =============================================================================
# DATA PRODUCT ACCESS
# Project roles for the optional Google Groups in var.data_product_groups. The
# data products grant read access on their own tables (data_products.tf). These
# are the roles a product cannot grant:
#
#   consumers  run queries, and find the products in Knowledge Catalog
#   stewards   keep the glossary, the aspects and the quality rules up to date
#
# With no groups set, nothing here is created.
# =============================================================================

locals {
  consumer_groups = compact([
    var.data_product_groups.analysts,
    var.data_product_groups.data_scientists,
  ])

  consumer_roles = [
    "roles/bigquery.jobUser",              # read access on a table is not enough to run a query
    "roles/dataplex.dataProductsConsumer", # browse the data products and request access
  ]

  steward_roles = [
    "roles/dataplex.catalogEditor",  # glossary, aspects and entries
    "roles/dataplex.dataScanEditor", # quality, profile and insights scans
  ]

  data_product_access = merge(
    {
      for pair in setproduct(local.consumer_groups, local.consumer_roles) :
      "${pair[0]} ${pair[1]}" => { group = pair[0], role = pair[1] }
    },
    var.data_product_groups.stewards == "" ? {} : {
      for role in local.steward_roles :
      "${var.data_product_groups.stewards} ${role}" => { group = var.data_product_groups.stewards, role = role }
    },
  )
}

resource "google_project_iam_member" "data_product_access" {
  for_each = local.data_product_access

  project = var.project_id
  role    = each.value.role
  member  = "group:${each.value.group}"
}
