#!/usr/bin/env bash
# Check that the demo is deployed and that a moment turns into a strategy call.
#
#   ./scripts/verify.sh --expect READY   every resource exists and is ready
#   ./scripts/verify.sh --smoke          publish a test moment and wait for its
#                                        call (one Gemini request)
#
# Reads project_id and region from the defaults in infra/variables.tf. Exits
# non-zero at the first check that fails.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARS="${ROOT}/infra/variables.tf"
tf_default() {
  sed -n "/variable \"$1\"/,/^}/{ s/^[[:space:]]*default[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p; }" "$VARS"
}
PROJECT="${PROJECT:-$(tf_default project_id)}"
REGION="${REGION:-$(tf_default region)}"
SESSION_KEY="$(tf_default openf1_session_key)"

MODE="${1:-}"
[[ "$MODE" == "--expect" ]] && MODE="--expect-${2:-READY}"

pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1" >&2; exit 1; }
check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}
bq_value() {
  bq --project_id="$PROJECT" query --use_legacy_sql=false --location=US --format=csv --quiet "$1" | tail -1
}
# GET a Google API with the CLI login. Fails on an HTTP error.
gcloud_api() {
  curl -sf -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "x-goog-user-project: ${PROJECT}" "$1"
}
# Knowledge Catalog keeps BigQuery metadata in the dataset's location.
CATALOG_LOCATION="$(tf_default dataset_location | tr '[:upper:]' '[:lower:]')"

expect_ready() {
  echo "Checking ${PROJECT} (${REGION})"
  check "race data in the bucket" \
    gcloud storage ls "gs://${PROJECT}-race-data/openf1/${SESSION_KEY}/car_data.json" --project="$PROJECT"
  for topic in race-events race-moments race-events-dead-letter; do
    check "topic ${topic}" gcloud pubsub topics describe "$topic" --project="$PROJECT"
  done
  for sub in race-events-bq race-moments-bq race-moments-strategist race-events-demo race-moments-demo; do
    check "subscription ${sub}" gcloud pubsub subscriptions describe "$sub" --project="$PROJECT"
  done
  check "car photos in the bucket" \
    gcloud storage ls "gs://${PROJECT}-race-data/media/cars/mclaren.jpg" --project="$PROJECT"
  for table in raw.raw_events serving.moments serving.calls raw.car_photos serving.cars serving.lap_debrief; do
    check "table ${table}" bq --project_id="$PROJECT" show "$table"
  done
  [[ "$(bq_value "SELECT COUNT(*) FROM \`${PROJECT}.serving.cars\` WHERE status = '' AND ARRAY_LENGTH(sponsors) > 0")" -ge 10 ]] \
    && pass "a reading for every car photo" || fail "a reading for every car photo"
  for product in race-telemetry race-strategy; do
    check "data product ${product}" gcloud_api \
      "https://dataplex.googleapis.com/v1/projects/${PROJECT}/locations/${CATALOG_LOCATION}/dataProducts/${product}"
  done
  for scan in raw-events-quality moments-quality calls-quality lap-debrief-quality; do
    check "quality scan ${scan}" gcloud dataplex datascans describe "$scan" --location="$REGION" --project="$PROJECT"
  done
  [[ "$(gcloud_api "https://geminidataanalytics.googleapis.com/v1beta/projects/${PROJECT}/locations/global/dataAgents" \
    | grep -c '"displayName": *"Pit wall race engineer"')" -ge 1 ]] \
    && pass "data agent Pit wall race engineer" || fail "data agent Pit wall race engineer"
  [[ "$(bq --project_id="$PROJECT" ls --reservation_assignment --location=US --format=json 2>/dev/null \
    | grep -c '"jobType": *"CONTINUOUS"')" -ge 1 ]] \
    && pass "CONTINUOUS reservation assignment" || fail "CONTINUOUS reservation assignment"
  check "replayer job" gcloud run jobs describe replayer --region="$REGION" --project="$PROJECT"
  for service in strategist pitwall; do
    [[ "$(gcloud run services describe "$service" --region="$REGION" --project="$PROJECT" \
      --format='value(status.conditions[0].status)')" == "True" ]] \
      && pass "service ${service} ready" || fail "service ${service} ready"
  done
  echo "READY"
}

smoke() {
  # The strategist answers from the replayed field, so the test moment borrows
  # the latest replay's run_id when there is one.
  local run_id
  run_id="$(bq_value "SELECT IFNULL((SELECT run_id FROM \`${PROJECT}.raw.raw_events\` WHERE event_type = 'drivers' ORDER BY publish_time DESC LIMIT 1), 'smoke-$(date +%s)')")"
  echo "Publishing a test SAFETY_CAR moment for run ${run_id}"
  gcloud pubsub topics publish race-moments --project="$PROJECT" --message="$(cat <<EOF
{"run_id":"${run_id}","moment":"SAFETY_CAR","driver_number":null,"lap":0,"event_ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","detail":"smoke test"}
EOF
)" >/dev/null

  echo -n "Waiting for the moment in serving.moments and its call in serving.calls"
  for _ in $(seq 1 18); do
    sleep 10
    echo -n "."
    local status
    status="$(bq_value "SELECT status FROM \`${PROJECT}.serving.calls\` WHERE run_id = '${run_id}' AND moment = 'SAFETY_CAR' ORDER BY created_at DESC LIMIT 1")"
    if [[ "$status" == "OK" ]]; then
      echo ""
      pass "moment answered with a strategy call"
      echo "SMOKE OK"
      return 0
    elif [[ "$status" == "FAILED" ]]; then
      echo ""
      fail "the strategist wrote a FAILED call (see serving.calls.error)"
    fi
  done
  echo ""
  fail "no call within 3 minutes (check the strategist logs in Cloud Run)"
}

case "$MODE" in
  --expect-READY) expect_ready ;;
  --smoke) smoke ;;
  *) sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
