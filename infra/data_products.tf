# =============================================================================
# DATA PRODUCTS
# Two data products, each owned by one (fictional) team. Race Strategy is
# built from Race Telemetry:
#
#   Race Telemetry ──> Race Strategy ──> the pit wall, the data agent, the debrief
#
# Everything lives in one project. The products come from ownership, not from
# project boundaries.
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
      assets = {
        raw-events = { dataset = "raw", table = "raw_events" }
        car-photos = { dataset = "raw", table = "car_photos" }
      }
    }
    race-strategy = {
      display_name = "Race Strategy"
      description  = "Owned by the Race Strategy team. The moments the continuous queries flag, the calls Gemini makes, a lap-by-lap debrief of every car and what Gemini reads in each car photo. Built from Race Telemetry. Used by the pit wall, the data agent and the post-race debrief."
      assets = {
        moments     = { dataset = "serving", table = "moments" }
        calls       = { dataset = "serving", table = "calls" }
        lap-debrief = { dataset = "serving", table = "lap_debrief" }
        cars        = { dataset = "serving", table = "cars" }
      }
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
  # The deployer's email is only known when the login has the email scope.
  # Without it, the scanner service account is listed as the owner.
  owner_emails = [coalesce(
    var.data_product_owner,
    data.google_client_openid_userinfo.deployer.email,
    google_service_account.data_scanner.email,
  )]

  labels = { domain = "pitwall" }

  depends_on = [time_sleep.api_propagation]
}

resource "google_dataplex_data_product_data_asset" "asset" {
  for_each = local.product_assets

  location        = local.catalog_location
  data_product_id = google_dataplex_data_product.product[each.value.product_id].data_product_id
  data_asset_id   = each.value.asset_id
  resource        = "//bigquery.googleapis.com/projects/${var.project_id}/datasets/${each.value.dataset}/tables/${each.value.table}"

  depends_on = [
    terraform_data.debrief,
    terraform_data.cars,
    google_bigquery_table.car_photos,
  ]
}
