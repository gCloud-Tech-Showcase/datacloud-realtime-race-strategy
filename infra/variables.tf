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

# 2025 Australian Grand Prix, race. Laps 30 to 50 hold two safety cars, the
# return of the rain and 31 pit stops.
variable "openf1_session_key" {
  description = "OpenF1 session_key of the race to replay"
  type        = string
  default     = "9693"

  validation {
    condition     = can(regex("^[0-9]+$", var.openf1_session_key))
    error_message = "openf1_session_key must be a number, for example 9693."
  }
}

variable "replay_window_start" {
  description = "Race time (UTC, ISO 8601) where the replay starts. Default: start of lap 30."
  type        = string
  default     = "2025-03-16T05:08:45"

  validation {
    condition     = can(regex("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}$", var.replay_window_start))
    error_message = "replay_window_start must look like 2025-03-16T05:08:45 (UTC, no zone suffix)."
  }
}

variable "replay_window_end" {
  description = "Race time (UTC, ISO 8601) where the replay ends. Default: end of lap 50."
  type        = string
  default     = "2025-03-16T05:50:30"

  validation {
    condition     = can(regex("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}$", var.replay_window_end))
    error_message = "replay_window_end must look like 2025-03-16T05:08:45 (UTC, no zone suffix)."
  }
}

variable "replay_speed" {
  description = "How many times faster than real time the replayer publishes the window"
  type        = string
  default     = "5"

  validation {
    condition     = can(tonumber(var.replay_speed)) && tonumber(var.replay_speed) > 0
    error_message = "replay_speed must be a positive number, for example 5."
  }
}

# Gap-closing rule in queries/03b-moments-windowed.sql. TUMBLE windows close
# on arrival time in BigQuery, so at replay_speed 5 a 30-second window covers
# 2.5 minutes of racing.
variable "window_seconds" {
  description = "TUMBLE window, in seconds of arrival time, for the gap-closing rule"
  type        = number
  default     = 30
}

variable "gap_closing_seconds" {
  description = "How many seconds the gap to the car ahead must shrink within one window to flag GAP_CLOSING"
  type        = number
  default     = 1
}

variable "pit_wall_viewers" {
  description = "IAM members allowed to open the pit wall, for example [\"user:you@example.com\"]. scripts/setup.sh writes your gcloud account to viewer.auto.tfvars."
  type        = list(string)
  default     = []
}
