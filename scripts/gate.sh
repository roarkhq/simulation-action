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
readonly SAVE_AS_PLAN="${INPUT_SAVE_AS_PLAN:-false}"
readonly VARIABLES="${INPUT_VARIABLES:-}"
readonly MIN_PASS_RATE="${INPUT_MIN_PASS_RATE:-}"
readonly TIMEOUT_MINUTES="${INPUT_TIMEOUT_MINUTES:-30}"
readonly POLL_INTERVAL="${INPUT_POLL_INTERVAL_SECONDS:-15}"
readonly FAIL_ON_TIMEOUT="${INPUT_FAIL_ON_TIMEOUT:-true}"
readonly CANCEL_ON_EXIT="${INPUT_CANCEL_ON_EXIT:-true}"
readonly PLATFORM_URL="${ROARK_PLATFORM_URL:-https://platform.roark.ai}"

# How many consecutive poll failures to absorb before giving up. A run takes
# minutes and a poll is one HTTPS call, so a single blip is overwhelmingly likely
# to be the network rather than a real problem. Failing the build on it would
# teach people the gate is flaky and to ignore it.
readonly MAX_POLL_FAILURES=5

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
if [[ "$SAVE_AS_PLAN" == 'true' && -z "$CONFIG" ]]; then
  die "'save-as-plan' applies to 'config' only. A run started from 'plan-id' is already using a saved plan."
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

  # Without `saveAsPlan` a YAML config runs as a one-off: the API still creates a
  # plan to carry it, but it stays hidden rather than cluttering the saved plans.
  # With it, the plan is kept and its id is reported, so a pipeline can bootstrap a
  # plan on its first run and pass `plan-id` from then on.
  python3 -c '
import json, sys, yaml
plan = yaml.safe_load(open(sys.argv[1])) or {}
print(json.dumps(plan))
' "$CONFIG" | jq --argjson variables "$variables" --argjson save "$SAVE_AS_PLAN" \
    '{ plan: ., variables: $variables, saveAsPlan: $save }'
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

plan_id="$(printf '%s' "$start_response" | jq -r '.data.simulationRunPlanId // .simulationRunPlanId // empty')"
run_url="${PLATFORM_URL}/simulations/runs/${run_id}"
emit "run-id=${run_id}"
emit "run-url=${run_url}"
emit "plan-id=${plan_id}"
printf '▶ Simulation started: %s\n' "$run_url"
if [[ "$SAVE_AS_PLAN" == 'true' && -n "$plan_id" ]]; then
  printf '  Saved as run plan %s. Pass it as plan-id to reuse this configuration.\n' "$plan_id"
fi

# ─── Stop the run if CI goes away ────────────────────────────────────────────
# A cancelled workflow leaves the simulation running: it keeps placing real calls
# for a result nobody will read, and the customer is billed for them. Cancel on the
# way out instead. Best-effort and never the reason the step fails, and idempotent
# server-side, so a run that finished a moment earlier is a no-op.
cancel_run() {
  [[ "$CANCEL_ON_EXIT" == 'true' ]] || return 0
  printf '::warning::Cancelled. Stopping Roark run %s.\n' "$run_id"
  roark simulation plan job cancel "$run_id" >/dev/null 2>&1 || true
}
trap 'cancel_run; exit 130' INT TERM

# ─── Wait for it ─────────────────────────────────────────────────────────────
deadline=$((SECONDS + TIMEOUT_MINUTES * 60))
status='PENDING'
poll_response=''
consecutive_failures=0

while :; do
  if poll_response="$(roark simulation plan job get "$run_id" 2>&1)"; then
    status="$(printf '%s' "$poll_response" | jq -r '.data.status // .status // empty')"
  else
    status=''
  fi

  if [[ -z "$status" ]]; then
    consecutive_failures=$((consecutive_failures + 1))
    if ((consecutive_failures >= MAX_POLL_FAILURES)); then
      die "Could not read run ${run_id} after ${MAX_POLL_FAILURES} consecutive attempts: ${poll_response}"
    fi
    printf '::warning::Could not read run %s (attempt %s of %s), retrying.\n' \
      "$run_id" "$consecutive_failures" "$MAX_POLL_FAILURES"
  else
    consecutive_failures=0
    is_terminal "$status" && break
    printf '  %s … waiting\n' "$status"
  fi

  if ((SECONDS >= deadline)); then
    emit "verdict=TIMED_OUT"
    summary "### ⏱ Roark simulation did not finish within ${TIMEOUT_MINUTES} minutes"
    summary ""
    summary "Last status: \`${status:-unknown}\` · [View run](${run_url})"
    cancel_run
    if [[ "$FAIL_ON_TIMEOUT" == 'true' ]]; then
      die "Timed out after ${TIMEOUT_MINUTES} minutes waiting for run ${run_id} (last status: ${status:-unknown})."
    fi
    # Deliberately not a failure: waiting longer than expected is our problem, and
    # blocking the merge on it would train people to ignore the gate. A real check
    # failure still fails, loudly.
    printf '::warning::Roark simulation timed out after %s minutes (last status: %s). Not failing because fail-on-timeout is false. %s\n' \
      "$TIMEOUT_MINUTES" "${status:-unknown}" "$run_url"
    exit 0
  fi

  sleep "$POLL_INTERVAL"
done

# The run is finished: there is nothing left to cancel, and leaving the trap armed
# would fire it on the exit code we are about to set.
trap - INT TERM

# ─── Turn the verdict into an exit code ──────────────────────────────────────
gate="$(printf '%s' "$poll_response" | jq -c '.data.gate // .gate // empty')"

if [[ -z "$gate" || "$gate" == 'null' ]]; then
  # Never treat a missing verdict as a pass — that would make the gate a silent
  # no-op, which is worse than a red build because nobody notices. A null verdict
  # means the run plan has no CI gate configured, not that the run was fine.
  die "This run returned no gate verdict. Enable the CI gate on the run plan and set its success criteria. Run: ${run_url}"
fi

passed="$(printf '%s' "$gate" | jq -r '.passed')"
pass_rate="$(printf '%s' "$gate" | jq -r '.passRate // empty')"
mode="$(printf '%s' "$gate" | jq -r '.mode // empty')"
min_pass_rate="${MIN_PASS_RATE:-$(printf '%s' "$gate" | jq -r '.minPassRate // empty')}"

# A pipeline-level override is applied here, on top of the server's verdict: the run
# plan stays the shared baseline while one branch holds itself to a higher bar. It
# can only tighten. Loosening would mean overruling the per-metric floors and the
# coverage checks the plan's owner set, which is not something a pipeline gets to do.
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
    elif .type == "NO_CHECKS_EVALUATED"        then "- No pass/fail checks were evaluated. The run plan has a gate but no metrics that produce a verdict."
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
