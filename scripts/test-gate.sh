#!/usr/bin/env bash
#
# Runs gate.sh end to end against a fake `roark` CLI, one verdict per case, and
# checks the exit code and the `verdict` output each one turns into. No API key and
# no real calls.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/roark" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == 'simulation' && "$2" == 'run' ]]; then
  cat >/dev/null
  echo '{"data":{"simulationRunPlanJobId":"run-1","simulationRunPlanId":"plan-1"}}'
  exit 0
fi
if [[ "$1" == 'simulation' && "$2" == 'plan' ]]; then
  printf '{"data":{"status":"%s","verdict":%s}}\n' "$FAKE_STATUS" "$FAKE_VERDICT"
  exit 0
fi
exit 0
FAKE
chmod +x "$work/bin/roark"

failed=0

# expect <name> <run status> <passed> <failures json> <exit code> <verdict> <text the log must contain>
expect() {
  local name="$1" status="$2" passed="$3" failures="$4" want_code="$5" want_verdict="$6" want_text="$7"
  local verdict out code got_verdict
  verdict="{\"passed\":${passed},\"score\":80,\"countedSims\":10,\"checks\":[{\"metricDefinitionId\":\"m1\",\"metricName\":\"Booked\",\"passed\":${passed},\"passRate\":80,\"minPassRate\":80}],\"failures\":${failures}}"
  : >"$work/output"
  out="$(PATH="$work/bin:$PATH" INPUT_PLAN_ID=plan-1 FAKE_STATUS="$status" FAKE_VERDICT="$verdict" \
    GITHUB_OUTPUT="$work/output" bash "$here/gate.sh" 2>&1)"
  code=$?
  got_verdict="$(grep '^verdict=' "$work/output" | tail -1 | cut -d= -f2)"
  if [[ "$code" != "$want_code" || "$got_verdict" != "$want_verdict" || "$out" != *"$want_text"* ]]; then
    printf 'FAIL %s: exit %s (want %s), verdict %s (want %s)\n%s\n\n' \
      "$name" "$code" "$want_code" "$got_verdict" "$want_verdict" "$out"
    failed=1
  else
    printf 'ok   %s\n' "$name"
  fi
}

# shellcheck disable=SC2016 # the backticks are the Markdown the gate prints
expect 'a check below its minimum fails' COMPLETED false \
  '[{"type":"METRIC_BELOW_MIN_PASS_RATE","metricDefinitionId":"m1","metricName":"Booked","passRate":50,"minPassRate":80,"inherited":false}]' \
  1 FAILED '`Booked` passed 50% of simulations, below its own minimum of 80%.'

expect 'an agent that could not be reached fails' COMPLETED false \
  '[{"type":"AGENT_UNREACHABLE","unreachableCalls":2,"totalCalls":10,"agentName":"Best Buy"}]' \
  1 FAILED 'Best Buy could not be reached on 2 of 10 simulations (no answer, busy or declined), so those have no results.'

expect 'an agent that never spoke fails, even beside a failure on our side' COMPLETED false \
  '[{"type":"AGENT_NEVER_SPOKE","neverSpokeCalls":5,"totalCalls":10,"maxShare":20,"agentName":null},{"type":"PLATFORM_FAILURE","failedCalls":1,"totalCalls":10}]' \
  1 FAILED 'Your agent never spoke on 5 of 10 simulations, more than the 20% a run can pass with.'

expect 'a failure on our side skips' COMPLETED false \
  '[{"type":"PLATFORM_FAILURE","failedCalls":1,"totalCalls":10}]' \
  0 SKIPPED '1 of 10 simulations could not run because of a problem on our side.'

expect 'a failure on our side poisons a check below its minimum' COMPLETED false \
  '[{"type":"METRIC_BELOW_MIN_PASS_RATE","metricDefinitionId":"m1","metricName":"Booked","passRate":50,"minPassRate":80,"inherited":true},{"type":"PLATFORM_FAILURE","failedCalls":1,"totalCalls":10}]' \
  0 SKIPPED 'could not run because of a problem on our side'

expect 'a cancelled run skips and says what its checks cover' CANCELLED false \
  '[{"type":"RUN_NOT_COMPLETED","status":"CANCELLED","gradedSims":20,"plannedSims":57}]' \
  0 SKIPPED 'The run was cancelled after 20 of 57 simulations were graded. The checks cover those 20.'

expect 'a run stopped before anything was graded says so' TIMED_OUT false \
  '[{"type":"RUN_NOT_COMPLETED","status":"TIMED_OUT","gradedSims":0,"plannedSims":12}]' \
  0 SKIPPED 'The run ran out of time before any simulation was graded.'

expect 'an unknown failure type skips and still prints' COMPLETED false \
  '[{"type":"SOMETHING_NEW"}]' \
  0 SKIPPED '- SOMETHING_NEW'

expect 'a run that cleared every check passes' COMPLETED true '[]' 0 PASSED 'Passed'

exit "$failed"
