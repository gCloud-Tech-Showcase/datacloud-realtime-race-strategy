# =============================================================================
# BUSINESS GLOSSARY
# The race terms a reader needs, defined once in Knowledge Catalog and linked
# to the columns that hold them. Hover a linked column in BigQuery to see its
# definition. The data agent's glossary in agent.tf uses the same definitions.
# =============================================================================

locals {
  glossary_categories = {
    race = {
      display_name = "Race"
      description  = "What happens on track and how a replay records it."
    }
    strategy = {
      display_name = "Strategy"
      description  = "What the pit wall flags and decides."
    }
    car = {
      display_name = "Car"
      description  = "Tyres, gaps and pit stops for one car."
    }
  }

  # Each term lists the columns it defines, as dataset.table.column.
  glossary_terms = {
    replay = {
      category     = "race"
      display_name = "Replay"
      description  = "One run of the replayer job, identified by run_id. It publishes the same race events every time, at replay_speed times real time."
      columns = [
        "raw.raw_events.run_id",
        "serving.moments.run_id",
        "serving.calls.run_id",
        "serving.lap_debrief.run_id",
      ]
    }
    race-time = {
      category     = "race"
      display_name = "Race time"
      description  = "When a record became known during the real race, in UTC (2025-03-16 for the default race). Not when the replay ran: that is publish_time."
      columns = [
        "raw.raw_events.event_ts",
        "serving.moments.event_ts",
        "serving.lap_debrief.lap_end_ts",
      ]
    }
    race-event = {
      category     = "race"
      display_name = "Race event"
      description  = "One OpenF1 record, such as a lap, a pit stop or a weather reading, published to Pub/Sub and landed as one row in raw.raw_events."
      columns      = ["raw.raw_events.event_type", "raw.raw_events.payload"]
    }
    moment = {
      category     = "strategy"
      display_name = "Moment"
      description  = "A race situation that can change the plan, flagged by a continuous query: SAFETY_CAR, PIT_STOP, RAIN_STARTED or GAP_CLOSING."
      columns = [
        "serving.moments.moment",
        "serving.calls.moment",
        "serving.lap_debrief.moments",
      ]
    }
    gap-closing = {
      category     = "strategy"
      display_name = "Gap closing"
      description  = "A car whose gap to the car ahead shrank by at least gap_closing_seconds (1 second by default) within one TUMBLE window, so an overtake may be coming."
      columns      = []
    }
    strategy-call = {
      category     = "strategy"
      display_name = "Strategy call"
      description  = "Gemini's answer to one moment: for each car that should act, BOX (pit this lap, and the tyre to fit) or STAY OUT, and why."
      columns      = ["serving.calls.call_text", "serving.lap_debrief.call_text"]
    }
    tyre-compound = {
      category     = "car"
      display_name = "Tyre compound"
      description  = "The tyre a car is on. Dry: SOFT (fastest, wears quickly), MEDIUM, HARD (most durable). Wet: INTERMEDIATE (damp track) and WET (heavy rain)."
      columns      = ["serving.lap_debrief.compound"]
    }
    tyre-age = {
      category     = "car"
      display_name = "Tyre age"
      description  = "Laps on the current set of tyres, including laps the set ran before this stint."
      columns      = ["serving.lap_debrief.tyre_age_laps"]
    }
    gap-to-leader = {
      category     = "car"
      display_name = "Gap to leader"
      description  = "Seconds behind the car in P1 at the end of the lap. Empty for a lapped car."
      columns      = ["serving.lap_debrief.gap_to_leader_s"]
    }
    interval = {
      category     = "car"
      display_name = "Interval"
      description  = "Seconds behind the car directly ahead at the end of the lap."
      columns      = ["serving.lap_debrief.interval_s"]
    }
    pit-lane-time = {
      category     = "car"
      display_name = "Pit lane time"
      description  = "Seconds from pit entry to pit exit, about 20 in Melbourne. The stationary stop is a few seconds of it (stop_s). Pitting costs this time against cars that stay out."
      columns      = ["serving.lap_debrief.pit_lane_s"]
    }
  }

  glossary_links = merge([
    for term_id, term in local.glossary_terms : {
      for column in term.columns : "${term_id}:${column}" => {
        term_id = term_id
        dataset = split(".", column)[0]
        table   = split(".", column)[1]
        column  = split(".", column)[2]
      }
    }
  ]...)
}

resource "google_dataplex_glossary" "race_strategy" {
  location     = local.catalog_location
  glossary_id  = "race-strategy"
  display_name = "Race strategy"
  description  = "Terms used in the Race Telemetry and Race Strategy data products."

  depends_on = [time_sleep.api_propagation]
}

resource "google_dataplex_glossary_category" "category" {
  for_each = local.glossary_categories

  location     = local.catalog_location
  glossary_id  = google_dataplex_glossary.race_strategy.glossary_id
  category_id  = each.key
  parent       = google_dataplex_glossary.race_strategy.id
  display_name = each.value.display_name
  description  = each.value.description
}

resource "google_dataplex_glossary_term" "term" {
  for_each = local.glossary_terms

  location     = local.catalog_location
  glossary_id  = google_dataplex_glossary.race_strategy.glossary_id
  term_id      = each.key
  parent       = google_dataplex_glossary_category.category[each.value.category].id
  display_name = each.value.display_name
  description  = each.value.description
}

# A definition link from a column to the term that defines it. The link lives
# in the @bigquery entry group, next to the table it annotates.
resource "google_dataplex_entry_link" "term_to_column" {
  for_each = local.glossary_links

  project         = data.google_project.current.number
  location        = local.catalog_location
  entry_group_id  = "@bigquery"
  entry_link_id   = substr(replace(lower("${each.value.term_id}-${each.value.table}-${each.value.column}"), "_", "-"), 0, 63)
  entry_link_type = "${local.dataplex_types}/entryLinkTypes/definition"

  entry_references {
    name = "${local.bigquery_entry_prefix}/bigquery.googleapis.com/projects/${var.project_id}/datasets/${each.value.dataset}/tables/${each.value.table}"
    path = "Schema.${each.value.column}"
    type = "SOURCE"
  }

  entry_references {
    name = "projects/${data.google_project.current.number}/locations/${local.catalog_location}/entryGroups/@dataplex/entries/projects/${data.google_project.current.number}/locations/${local.catalog_location}/glossaries/${google_dataplex_glossary.race_strategy.glossary_id}/terms/${google_dataplex_glossary_term.term[each.value.term_id].term_id}"
    type = "TARGET"
  }

  depends_on = [time_sleep.debrief_catalog_entry]
}
