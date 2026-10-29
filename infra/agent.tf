# =============================================================================
# CONVERSATIONAL ANALYTICS DATA AGENT
# A BigQuery data agent for the post-race debrief, so anyone can ask about the
# replay in plain English. It appears under BigQuery > Agents. The verified
# queries pin how the questions that matter are answered, so answers match the
# SQL in queries/.
# =============================================================================

locals {
  agent_tables = {
    serving = ["lap_debrief", "moments", "calls", "cars"]
  }
  serving = "`${var.project_id}.serving`"

  # The latest replay that has a debrief. Race times repeat across replays.
  latest_run = "(SELECT run_id FROM ${local.serving}.lap_debrief ORDER BY replayed_at DESC LIMIT 1)"
}

# The provider's in-place update sends back the read-only last_published_context,
# which the API rejects ("Last published context should not be set"). A deleted
# agent also keeps its ID for 30 days. So any edit to this file creates a new
# agent under a new ID, then deletes the old one. Find the agent by its display
# name, not its ID.
resource "google_gemini_data_analytics_data_agent" "race_engineer" {
  location      = "global"
  data_agent_id = "race_engineer_${substr(filesha256("${path.module}/agent.tf"), 0, 8)}"
  display_name  = "Pit wall race engineer"
  description   = "Answers questions about each replay of ${var.race_name}: laps, tyres, pit stops, the moments the continuous queries flagged and the calls Gemini made."

  data_analytics_agent {
    published_context {
      system_instruction = <<-EOT
        You are the race engineer running the post-race debrief for ${var.race_name}.
        The data covers replays of laps 30 to 50 of a 57-lap race. Every replay
        publishes the same race, identified by run_id, so race times (event_ts,
        lap_end_ts) repeat across replays. Unless the user names a run_id, answer
        for the latest replay: the run_id with the latest replayed_at in
        lap_debrief.

        Prefer lap_debrief: one row per car per completed lap, with position,
        lap time, gaps, tyre compound and age, pit stops, rain, the moments
        flagged for that car on that lap and Gemini's call for it. Laps 1 to 29
        are history published at the start of the replay. Use moments for
        race-wide moments (SAFETY_CAR, RAIN_STARTED have no driver_number) and for
        detection lag. Use calls for every strategy call, its status and
        latency_ms. Use cars for livery colours and sponsors read from the car
        photos.

        Refer to drivers by their three-letter code (driver) and team. Report times
        in seconds with one decimal. A moment can appear twice in moments after a
        continuous query restarts, so count distinct (moment, driver_number,
        event_ts). Gemini's calls are recommendations, not what the team did:
        compare them with pitted in lap_debrief when asked.
      EOT

      datasource_references {
        bq {
          dynamic "table_references" {
            for_each = flatten([for dataset, tables in local.agent_tables : [for t in tables : { dataset = dataset, table = t }]])
            content {
              project_id = var.project_id
              dataset_id = table_references.value.dataset
              table_id   = table_references.value.table
            }
          }
        }
      }

      glossary_terms {
        display_name = "moment"
        description  = "A race situation flagged by a continuous query: SAFETY_CAR, PIT_STOP, RAIN_STARTED or GAP_CLOSING. Column moment in moments and calls, array moments in lap_debrief."
        labels       = ["race moment", "alert", "event"]
      }
      glossary_terms {
        display_name = "strategy call"
        description  = "Gemini's answer to one moment: BOX (pit, and the tyre to fit) or STAY OUT for each car that should act. Column call_text in calls and lap_debrief."
        labels       = ["call", "recommendation", "pit call"]
      }
      glossary_terms {
        display_name = "replay"
        description  = "One run of the replayer, identified by run_id. The latest replay has the latest replayed_at."
        labels       = ["run", "race run"]
      }
      glossary_terms {
        display_name = "detection lag"
        description  = "Seconds from a race event landing in BigQuery to its moment reaching Pub/Sub: TIMESTAMP_DIFF(moments.publish_time, raw event publish_time). Fast rules take seconds, the windowed GAP_CLOSING rule about a minute."
        labels       = ["lag", "latency to flag"]
      }
      glossary_terms {
        display_name = "pit lane time"
        description  = "Seconds from pit entry to pit exit, column pit_lane_s in lap_debrief, about 20 s in Melbourne. stop_s is the stationary part."
        labels       = ["pit loss", "pit stop time"]
      }
      glossary_terms {
        display_name = "tyre compound"
        description  = "SOFT, MEDIUM or HARD on a dry track, INTERMEDIATE or WET in the rain. Column compound in lap_debrief."
        labels       = ["tyre", "tire", "compound"]
      }

      example_queries {
        natural_language_question = "How many moments did the latest replay flag, by type?"
        sql_query                 = "SELECT moment, COUNT(DISTINCT TO_JSON_STRING(STRUCT(driver_number, event_ts))) AS moments FROM ${local.serving}.moments WHERE run_id = ${local.latest_run} AND event_ts <= (SELECT MAX(lap_end_ts) FROM ${local.serving}.lap_debrief) GROUP BY moment ORDER BY moments DESC"
      }
      example_queries {
        natural_language_question = "What did Gemini recommend when the rain started, and how long did the call take?"
        sql_query                 = "SELECT lap, ROUND(latency_ms / 1000, 1) AS seconds, call_text FROM ${local.serving}.calls WHERE run_id = ${local.latest_run} AND moment = 'RAIN_STARTED' AND status = 'OK' ORDER BY created_at"
      }
      example_queries {
        natural_language_question = "Who pitted in the latest replay, on which lap, and onto which tyre?"
        sql_query                 = "SELECT d.lap, d.driver, d.team, ROUND(d.pit_lane_s, 1) AS pit_lane_s, ROUND(d.stop_s, 1) AS stop_s, n.compound AS new_compound FROM ${local.serving}.lap_debrief AS d LEFT JOIN ${local.serving}.lap_debrief AS n ON n.run_id = d.run_id AND n.driver_number = d.driver_number AND n.lap = d.lap + 1 WHERE d.run_id = ${local.latest_run} AND d.pitted ORDER BY d.lap, d.driver"
      }
      example_queries {
        natural_language_question = "Which cars had the most closing-gap alerts, and what did Gemini tell them?"
        sql_query                 = "SELECT driver, team, COUNT(*) AS gap_closing_laps, ARRAY_AGG(call_text IGNORE NULLS ORDER BY lap DESC LIMIT 1)[SAFE_OFFSET(0)] AS latest_call FROM ${local.serving}.lap_debrief WHERE run_id = ${local.latest_run} AND 'GAP_CLOSING' IN UNNEST(moments) GROUP BY driver, team ORDER BY gap_closing_laps DESC, driver"
      }
      example_queries {
        natural_language_question = "How did the top five's tyres and lap times change after the rain started?"
        sql_query                 = "SELECT lap, position, driver, compound, tyre_age_laps, ROUND(lap_s, 1) AS lap_s, raining FROM ${local.serving}.lap_debrief WHERE run_id = ${local.latest_run} AND lap BETWEEN 42 AND 50 AND position <= 5 ORDER BY lap, position"
      }
      example_queries {
        natural_language_question = "How fast were the strategy calls?"
        sql_query                 = "SELECT moment, COUNT(*) AS calls, COUNTIF(status = 'OK') AS ok, ROUND(MIN(latency_ms) / 1000, 1) AS fastest_s, ROUND(APPROX_QUANTILES(latency_ms, 2)[OFFSET(1)] / 1000, 1) AS median_s, ROUND(MAX(latency_ms) / 1000, 1) AS slowest_s FROM ${local.serving}.calls WHERE run_id = ${local.latest_run} GROUP BY moment ORDER BY calls DESC"
      }
      example_queries {
        natural_language_question = "Which teams carry Google or Gemini branding on their cars?"
        sql_query                 = "SELECT team, ARRAY_TO_STRING(ARRAY(SELECT s FROM UNNEST(sponsors) AS s WHERE LOWER(s) LIKE '%google%' OR LOWER(s) LIKE '%gemini%'), ', ') AS google_brands FROM ${local.serving}.cars WHERE EXISTS (SELECT 1 FROM UNNEST(sponsors) AS s WHERE LOWER(s) LIKE '%google%' OR LOWER(s) LIKE '%gemini%') ORDER BY team"
      }
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    time_sleep.api_propagation,
    terraform_data.debrief,
    terraform_data.cars,
  ]
}
