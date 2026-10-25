# =============================================================================
# OUTPUTS
# =============================================================================

output "project_id" {
  description = "The GCP project ID"
  value       = var.project_id
}

output "raw_dataset_id" {
  description = "The dataset holding raw_events"
  value       = google_bigquery_dataset.stages["raw"].dataset_id
}

output "serving_dataset_id" {
  description = "The dataset holding moments and calls"
  value       = google_bigquery_dataset.stages["serving"].dataset_id
}

output "data_bucket" {
  description = "The GCS bucket holding the downloaded race data"
  value       = google_storage_bucket.race_data.name
}

output "vertex_ai_connection_id" {
  description = "The BigQuery connection that calls Gemini"
  value       = google_bigquery_connection.vertex_ai.id
}

output "pit_wall_proxy_command" {
  description = "Run this, then open http://localhost:8080 to see the pit wall"
  value       = "gcloud run services proxy ${google_cloud_run_v2_service.pitwall.name} --region=${var.region} --project=${var.project_id}"
}
