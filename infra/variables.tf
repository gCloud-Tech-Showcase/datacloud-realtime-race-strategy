# =============================================================================
# VARIABLES
# Every variable has a working default, so a clone is `setup.sh` then `apply`
# with no tfvars file. The `project_id` default is the single source of truth:
# providers, resources, derived bucket names and scripts/setup.sh all read it.
# =============================================================================

variable "project_id" {
  description = "The GCP project ID (created out-of-band as a one-time prerequisite)"
  type        = string
  default     = "datacloud-pitwall"
}

variable "region" {
  description = "The GCP region for regional resources (the data bucket and the saved queries)"
  type        = string
  default     = "us-central1"
}

variable "dataset_location" {
  description = "BigQuery dataset location (multi-region). Also where setup.sh puts the state bucket, because state is the one artifact that cannot be rebuilt."
  type        = string
  default     = "US"
}
