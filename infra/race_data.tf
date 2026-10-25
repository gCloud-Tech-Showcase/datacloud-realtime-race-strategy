# =============================================================================
# RACE DATA
# Downloads the race from the OpenF1 historical API into the race-data bucket
# during apply. It runs on the machine that runs `tofu apply`, so nothing in the
# project needs internet access and no F1 data is committed to the repo.
# =============================================================================

resource "terraform_data" "race_data" {
  # Download again when the race or the replay window changes.
  triggers_replace = [
    google_storage_bucket.race_data.name,
    var.openf1_session_key,
    var.replay_window_start,
    var.replay_window_end,
  ]

  provisioner "local-exec" {
    command = "python3 ${path.module}/scripts/load_race_data.py ${google_storage_bucket.race_data.name} ${var.openf1_session_key} ${var.replay_window_start} ${var.replay_window_end}"
  }
}
