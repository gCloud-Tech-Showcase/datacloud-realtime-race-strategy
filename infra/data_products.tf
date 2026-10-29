# =============================================================================
# DATA PRODUCTS
# Two data products, each owned by one (fictional) team. Race Strategy is
# built from Race Telemetry:
#
#   Race Telemetry ──> Race Strategy ──> the pit wall, the data agent, the debrief
#
# Each product has its own owning team, and both live in the same project.
#
# With var.data_product_groups set, Google Groups take the roles: an owner
# group per product, stewards who approve access requests, and two consumer
# access groups. Analysts read Race Strategy. Data scientists read both.
# =============================================================================

locals {
  # BigQuery tables are catalogued in their dataset's location: "us" for the
  # US multi-region. Data products, glossary links and aspects live there too.
  # The scans run in var.region (data_scans.tf).
  catalog_location = lower(var.dataset_location)

  # Knowledge Catalog creates an entry for every BigQuery table in the
  # @bigquery entry group. Aspects and glossary links attach to those entries.
  bigquery_entry_prefix = "projects/${data.google_project.current.number}/locations/${local.catalog_location}/entryGroups/@bigquery/entries"

  # System entry types (bigquery-table) and the glossary definition link type
  # live in this Google-owned project. The API returns its number, so using the
  # number keeps tofu plan clean.
  dataplex_types = "projects/655216118709/locations/global"

  data_products = {
    race-telemetry = {
      display_name = "Race Telemetry"
      description  = "Owned by Trackside Engineering. Every OpenF1 record of each replay of ${var.race_name}, laps 30 to 50 by default, as it arrived from Pub/Sub, and one photo per team. Used by Race Strategy."
      owner_group  = var.data_product_groups.telemetry_owners
      assets = {
        raw-events = { dataset = "raw", table = "raw_events" }
        car-photos = { dataset = "raw", table = "car_photos" }
      }
    }
    race-strategy = {
      display_name = "Race Strategy"
      description  = "Owned by the Race Strategy team. The moments the continuous queries flag, the calls Gemini makes, a lap-by-lap debrief of every car and what Gemini reads in each car photo. Built from Race Telemetry. Used by the pit wall, the data agent and the post-race debrief."
      owner_group  = var.data_product_groups.strategy_owners
      assets = {
        moments     = { dataset = "serving", table = "moments" }
        calls       = { dataset = "serving", table = "calls" }
        lap-debrief = { dataset = "serving", table = "lap_debrief" }
        cars        = { dataset = "serving", table = "cars" }
      }
    }
  }

  # Consumer access groups, from var.data_product_groups. Each group gets read
  # access to every table of the products listed under it, through group
  # membership. Groups left empty are skipped.
  access_groups = {
    analyst = {
      display_name = "Race analysts"
      description  = "Read the curated race strategy tables: moments, calls, the lap-by-lap debrief and cars."
      group        = var.data_product_groups.analysts
      products     = ["race-strategy"]
    }
    data-scientist = {
      display_name = "Race data scientists"
      description  = "Read the curated tables, and the raw race events and car photos behind them."
      group        = var.data_product_groups.data_scientists
      products     = ["race-telemetry", "race-strategy"]
    }
  }

  # The access groups of each product, keyed by product ID.
  product_access_groups = {
    for product_id in keys(local.data_products) : product_id => {
      for group_id, g in local.access_groups : group_id => g
      if g.group != "" && contains(g.products, product_id)
    }
  }

  # Every asset across the two products, keyed by table name.
  product_assets = merge([
    for product_id, product in local.data_products : {
      for asset_id, asset in product.assets : asset.table => merge(asset, {
        product_id = product_id
        asset_id   = asset_id
      })
    }
  ]...)
}

data "google_project" "current" {}

data "google_client_openid_userinfo" "deployer" {}

resource "google_dataplex_data_product" "product" {
  for_each = local.data_products

  location        = local.catalog_location
  data_product_id = each.key
  display_name    = each.value.display_name
  description     = each.value.description
  # An owner group from var.data_product_groups comes first. Otherwise the
  # deployer's email, which is only known when the login has the email scope.
  # Without it, the scanner service account is listed as the owner.
  owner_emails = [coalesce(
    each.value.owner_group,
    var.data_product_owner,
    data.google_client_openid_userinfo.deployer.email,
    google_service_account.data_scanner.email,
  )]

  # The stewards are notified of access requests and approve them.
  dynamic "access_approval_config" {
    for_each = var.data_product_groups.stewards != "" ? [var.data_product_groups.stewards] : []
    content {
      approver_emails = [access_approval_config.value]
    }
  }

  dynamic "access_groups" {
    for_each = local.product_access_groups[each.key]
    content {
      id           = access_groups.key
      group_id     = access_groups.key
      display_name = access_groups.value.display_name
      description  = access_groups.value.description
      principal {
        google_group = access_groups.value.group
      }
    }
  }

  labels = { domain = "pitwall" }

  depends_on = [time_sleep.api_propagation]
}

resource "google_dataplex_data_product_data_asset" "asset" {
  for_each = local.product_assets

  location        = local.catalog_location
  data_product_id = google_dataplex_data_product.product[each.value.product_id].data_product_id
  data_asset_id   = each.value.asset_id
  resource        = "//bigquery.googleapis.com/projects/${var.project_id}/datasets/${each.value.dataset}/tables/${each.value.table}"

  # Knowledge Catalog grants these roles on the table to each access group of
  # the product, and removes them when the asset or the group goes.
  dynamic "access_group_configs" {
    for_each = local.product_access_groups[each.value.product_id]
    content {
      access_group = access_group_configs.key
      iam_roles    = ["roles/bigquery.dataViewer"]
    }
  }

  depends_on = [
    terraform_data.debrief,
    terraform_data.cars,
    google_bigquery_table.car_photos,
  ]
}
