#!/usr/bin/env bash
#
# Start a Roark simulation, wait for it, and turn its verdict into an exit code.
#
# The pass/fail decision itself is made by Roark, from the success criteria on the
# run plan, so every consumer (this action, the CLI, the dashboard) agrees on
# whether a run passed. This script only transports that verdict into CI.
#
set -euo pipefail

readonly PLAN_ID="${INPUT_PLAN_ID:-}"
readonly CONFIG="${INPUT_CONFIG:-}"
readonly VARIABLES="${INPUT_VARIABLES:-}"
readonly MIN_PASS_RATE="${INPUT_MIN_PASS_RATE:-}"
readonly TIMEOUT_MINUTES="${INPUT_TIMEOUT_MINUTES:-30}"
readonly POLL_INTERVAL="${INPUT_POLL_INTERVAL_SECONDS:-15}"
readonly FAIL_ON_TIMEOUT="${INPUT_FAIL_ON_TIMEOUT:-true}"
readonly PLATFORM_URL="${ROARK_PLATFORM_URL:-https://platform.roark.ai}"

# Terminal states. Only COMPLETED can carry a verdict; the rest are hard failures
# because there is no meaningful pass rate to judge.
is_terminal() {
  case "$1" in
    COMPLETED | FAILED | CANCELLED | TIMED_OUT) return 0 ;;
    *) return 1 ;;
  esac
}

emit() { printf '%s\n' "$1" >>"${GITHUB_OUTPUT:-/dev/null}"; }
summary() { printf '%s\n' "$1" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"; }
die() {
  printf '::error::%s\n' "$1"
  exit 1
}

# ─── Validate inputs ─────────────────────────────────────────────────────────
if [[ -n "$PLAN_ID" && -n "$CONFIG" ]]; then
  die "Provide either 'plan-id' or 'config', not both."
fi
if [[ -z "$PLAN_ID" && -z "$CONFIG" ]]; then
  die "Provide 'plan-id' (a saved run plan) or 'config' (a YAML file describing the run)."
fi
if [[ -n "$CONFIG" && ! -f "$CONFIG" ]]; then
  die "Config file not found: ${CONFIG}"
fi

# ─── Build the request body ──────────────────────────────────────────────────
# `variables` arrives as KEY=VALUE lines; the API wants an object. Sliced at the
# FIRST '=' so a value may carry both '=' and spaces ("customerName=John Doe") —
# splitting on whitespace silently dropped those. Blank lines and '#' comments are
# ignored; a line with no '=' is skipped rather than becoming a null value.
variables_json() {
  if [[ -z "$VARIABLES" ]]; then
    printf '{}'
    return
  fi
  printf '%s' "$VARIABLES" | jq -R -s -c '
    split("\n")
    | map(rtrimstr("\r"))
    | map(select(length > 0 and (startswith("#") | not) and (index("=") != null)))
    | map({ (.[:index("=")] | gsub("^\\s+|\\s+$"; "")): (.[index("=")+1:] | gsub("^\\s+|\\s+$"; "")) })
    | add // {}
  '
}

build_body() {
  local variables
  variables="$(variables_json)"

  if [[ -n "$PLAN_ID" ]]; then
    jq -n --arg planId "$PLAN_ID" --argjson variables "$variables" \
      '{ planId: $planId, variables: $variables }'
    return
  fi

  # A YAML config runs as a one-off: the API still creates a plan to carry it,
  # but it stays hidden rather than cluttering the customer's saved plans.
  python3 -c '
import json, sys, yaml
plan = yaml.safe_load(open(sys.argv[1])) or {}
print(json.dumps(plan))
' "$CONFIG" | jq --argjson variables "$variables" '{ plan: ., variables: $variables }'
}

# ─── Start the run ───────────────────────────────────────────────────────────
body="$(build_body)"
printf '::group::Starting simulation\n'
printf '%s\n' "$body" | jq .
printf '::endgroup::\n'

start_response="$(printf '%s' "$body" | roark simulation run --body @- 2>&1)" ||
  die "Failed to start the simulation: ${start_response}"

run_id="$(printf '%s' "$start_response" | jq -r '.data.simulationRunPlanJobId // .simulationRunPlanJobId // empty')"
[[ -n "$run_id" ]] || die "Could not read a run id from the API response: ${start_response}"

run_url="${PLATFORM_URL}/simulations/runs/${run_id}"
emit "run-id=${run_id}"
emit "run-url=${run_url}"
printf '▶ Simulation started: %s\n' "$run_url"

# ─── Wait for it ─────────────────────────────────────────────────────────────
deadline=$((SECONDS + TIMEOUT_MINUTES * 60))
status='PENDING'
poll_response=''

while :; do
  poll_response="$(roark simulation plan job get "$run_id" 2>&1)" ||
    die "Failed to read run ${run_id}: ${poll_response}"

  status="$(printf '%s' "$poll_response" | jq -r '.data.status // .status // empty')"
  [[ -n "$status" ]] || die "Could not read a status from the API response: ${poll_response}"

  is_terminal "$status" && break

  if ((SECONDS >= deadline)); then
    emit "verdict=TIMED_OUT"
    summary "### ⏱ Roark simulation did not finish within ${TIMEOUT_MINUTES} minutes"
    summary ""
    summary "Last status: \`${status}\` · [View run](${run_url})"
    if [[ "$FAIL_ON_TIMEOUT" == 'true' ]]; then
      die "Timed out after ${TIMEOUT_MINUTES} minutes waiting for run ${run_id} (last status: ${status})."
    fi
    # Deliberately not a failure: waiting longer than expected is our problem, and
    # blocking the merge on it would train people to ignore the gate. A real check
    # failure still fails, loudly.
    printf '::warning::Roark simulation timed out after %s minutes (last status: %s). Not failing because fail-on-timeout is false. %s\n' \
      "$TIMEOUT_MINUTES" "$status" "$run_url"
    exit 0
  fi

  printf '  %s … waiting\n' "$status"
  sleep "$POLL_INTERVAL"
done

# ─── Turn the verdict into an exit code ──────────────────────────────────────
gate="$(printf '%s' "$poll_response" | jq -c '.data.gate // .gate // empty')"

if [[ -z "$gate" || "$gate" == 'null' ]]; then
  # Never treat a missing verdict as a pass — that would make the gate a silent
  # no-op, which is worse than a red build because nobody notices.
  die "This run returned no gate verdict. Enable the CI gate on the run plan and set its success criteria. Run: ${run_url}"
fi

if [[ "$(printf '%s' "$gate" | jq -r '.enabled')" != 'true' ]]; then
  die "The CI gate is not enabled on this run plan, so there is nothing to gate on. Enable it and set success criteria. Run: ${run_url}"
fi

passed="$(printf '%s' "$gate" | jq -r '.passed')"
pass_rate="$(printf '%s' "$gate" | jq -r '.passRate // empty')"
mode="$(printf '%s' "$gate" | jq -r '.mode // empty')"
min_pass_rate="${MIN_PASS_RATE:-$(printf '%s' "$gate" | jq -r '.minPassRate // empty')}"

# A pipeline-level override is applied here, on top of the server's verdict: the
# run plan stays the shared baseline while one branch holds itself to a higher bar.
if [[ -n "$MIN_PASS_RATE" ]]; then
  if [[ -z "$pass_rate" ]]; then
    passed='false'
  elif awk "BEGIN { exit !($pass_rate < $MIN_PASS_RATE) }"; then
    passed='false'
  fi
fi

emit "pass-rate=${pass_rate}"

render_failures() {
  printf '%s' "$gate" | jq -r '
    (.failures // [])[] |
    if   .type == "BELOW_MIN_PASS_RATE"        then "- Run pass rate \(.passRate // "none")% is below the required \(.minPassRate)% (\(.mode))"
    elif .type == "METRIC_BELOW_REQUIRED_PASS_RATE" then "- `\(.metricName // .metricDefinitionId)` passed \(.passRate)% of calls, below its required \(.requiredPassRate)%"
    elif .type == "METRIC_NOT_EVALUATED"       then "- `\(.metricName // .metricDefinitionId)` was never evaluated on any call"
    elif .type == "INCOMPLETE_COVERAGE"        then "- Only \(.evaluatedCalls) of \(.expectedCalls) calls were evaluated"
    elif .type == "RUN_NOT_COMPLETED"          then "- The run did not complete (\(.status))"
    else "- \(.type)" end
  '
}

if [[ "$passed" == 'true' ]]; then
  emit "verdict=PASSED"
  summary "### ✅ Roark simulation passed"
  summary ""
  summary "**${pass_rate}%** pass rate (${mode}), minimum **${min_pass_rate}%**"
  summary ""
  summary "[View run](${run_url})"
  printf '✅ Passed — %s%% (%s), min %s%%\n%s\n' "$pass_rate" "$mode" "$min_pass_rate" "$run_url"
  exit 0
fi

emit "verdict=FAILED"
summary "### ❌ Roark simulation failed"
summary ""
summary "**${pass_rate:-no}%** pass rate (${mode}), minimum **${min_pass_rate}%**"
summary ""
render_failures >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
summary ""
summary "[View run](${run_url})"

printf '❌ Failed — %s%% (%s), min %s%%\n' "${pass_rate:-no}" "$mode" "$min_pass_rate"
render_failures
printf '%s\n' "$run_url"
exit 1
