# Roark Simulation Gate

Run a [Roark](https://roark.ai) voice-agent simulation from CI and gate the pipeline on the result.

Your agent gets called by simulated customers, every call is scored against the metrics you configured, and the step fails when the run misses the success criteria on its run plan.

```yaml
- uses: roarkhq/simulation-action@v1
  with:
    api-token: ${{ secrets.ROARK_API_KEY }}
    plan-id: 3a1d5e7c-9b2f-4a6d-8c31-5f7e9d0a2b4c
```

## How the pass/fail decision is made

Roark decides, not this action. You configure **success criteria** on the run plan and the API returns a verdict, so the CLI, the dashboard and this action always agree on whether a run passed.

Criteria are pinned to each run when it starts, so editing a plan never rewrites the verdict of a run that already happened.

**Every check is judged on its own.** A check is one pass/fail metric: a yes/no metric, or a threshold on a numeric one. Each must reach its own minimum pass rate across the run, and the run passes only when all of them do.

| Check | Passed | Rate | Minimum | |
|---|---|---|---|---|
| silence duration < 500ms | 4/10 | 40% | 40% | pass |
| word count < 1000 | 7/10 | 70% | 80% | **fail** |

The run **fails**. `word count` missed its own bar, and no amount of success elsewhere makes up for it.

That is the whole decision. There is no pooled average to clear: averaging would let a check at 0% hide behind checks at 100%, which is exactly the failure a gate exists to catch.

### Minimums

The plan sets one **default minimum** that every check inherits, and any check can override it with its own (*"silence duration only has to clear 40%"*). A check is judged against its override when it has one, otherwise the default. Nothing else affects pass or fail.

### Score is not the decision

The run also reports a **score**: the weighted mean of the check rates, using the optional `weight` on each metric. It is for dashboards and trend lines only.

Nothing is gated on it, and you should not gate on it either. A run can score 95 and fail (one non-negotiable check missed its bar) or score 40 and pass (every check cleared a deliberately low bar). Weight shapes the score; it never rescues or sinks a check. Setting a weight to `0` drops a check from the score while still holding it to its minimum.

A run **fails** when it did not complete, when a check never ran, when some calls dropped out of scoring, or when any check is below its minimum. None of those pass silently, and a run with no verdict at all fails rather than going quietly green.
## Usage

### Run a saved plan

Configure the criteria once in the Roark platform, then:

```yaml
name: Voice agent regression
on:
  push:
    branches: [main]

jobs:
  simulate:
    runs-on: ubuntu-latest
    steps:
      - uses: roarkhq/simulation-action@v1
        with:
          api-token: ${{ secrets.ROARK_API_KEY }}
          plan-id: 3a1d5e7c-9b2f-4a6d-8c31-5f7e9d0a2b4c
          variables: |
            orderNumber=12345
            customerName=John Doe
```

### Or keep the config in your repo

```yaml
# .roark/checkout-regression.yml
name: Checkout regression
direction: OUTBOUND
maxSimulationDurationSeconds: 300
agentEndpoints:
  - id: 7c9e6679-7425-40de-944b-e07fc1f90ae7
flows:
  - id: 550e8400-e29b-41d4-a716-446655440000
    happyPath: true
    edgeCases: ALL
metrics:
  - slug: agent_containment
    # No minPassRate, so it inherits the default below.
  - slug: latency
    minPassRate: 12    # this check only has to clear 12%
    weight: 0          # ... and is left out of the reported score entirely
  - slug: leaked_pii
    expectedBooleanValue: false    # this check passes when the answer is FALSE
successCriteria:
  minPassRate: 90    # the default every check above is held to on its own
```

```yaml
      - uses: actions/checkout@v4
      - uses: roarkhq/simulation-action@v1
        with:
          api-token: ${{ secrets.ROARK_API_KEY }}
          config: .roark/checkout-regression.yml
```

This runs as a one-off: nothing is added to your saved plans.

Set `save-as-plan: true` to keep it instead. The plan id comes back as the `plan-id`
output, so a pipeline can create the plan on its first run and pass `plan-id` from
then on:

```yaml
      - uses: roarkhq/simulation-action@v1
        id: sim
        with:
          api-token: ${{ secrets.ROARK_API_KEY }}
          config: .roark/checkout-regression.yml
          save-as-plan: true
      - run: echo "Plan ${{ steps.sim.outputs.plan-id }}"
```

### Hold one branch to a higher bar

`min-pass-rate` holds every check to at least that minimum for this pipeline only, leaving
the shared plan alone. It is applied per check, on top of each check's own minimum, so a
release branch can demand more than the plan without touching it.

It can only tighten: it will not let through a run the plan's own criteria failed, because
overruling a minimum the plan's owner set is not something a pipeline gets to do.

```yaml
      - uses: roarkhq/simulation-action@v1
        with:
          api-token: ${{ secrets.ROARK_API_KEY }}
          plan-id: 3a1d5e7c-9b2f-4a6d-8c31-5f7e9d0a2b4c
          min-pass-rate: 99
```

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `api-token` | yes | | Roark API key. Pass it from a secret. |
| `plan-id` | one of | | Saved run plan to run. |
| `config` | one of | | Path to a YAML file describing the run. |
| `variables` | no | | Runtime variables, one `KEY=VALUE` per line. |
| `save-as-plan` | no | `false` | Keep the `config` as a named run plan instead of running it as a one-off. |
| `min-pass-rate` | no | | Hold every check to at least this minimum (0-100) for this pipeline. Tightens only. |
| `timeout-minutes` | no | `30` | How long to wait for the run. |
| `poll-interval-seconds` | no | `15` | How often to check for completion. |
| `fail-on-timeout` | no | `true` | `false` warns instead of failing when the run overruns. |
| `cancel-on-exit` | no | `true` | Stop the Roark run when the workflow is cancelled or the wait times out. |
| `cli-version` | no | pinned | Version of `@roarkanalytics/cli` to run. |
| `api-base-url` | no | `https://api.roark.ai` | Override the API base URL. |

## Outputs

| Output | Description |
|---|---|
| `run-id` | The simulation run id. |
| `run-url` | Link to the run in the Roark platform. |
| `plan-id` | The run plan behind this run. With `save-as-plan`, the plan that was kept. |
| `score` | The run's quality score, 0-100. Reporting only: gate on `verdict`, never this. |
| `checks-passed` | How many checks cleared their own minimum. |
| `checks-total` | How many checks the run was judged on. |
| `verdict` | `PASSED`, `FAILED`, or `TIMED_OUT`. |

## Simulations take minutes

Real calls take real time, so a gated run occupies a runner while it waits. Four ways to
keep that cheap and predictable:

- **Run it where it matters.** Gate `main` or your release branch rather than every push to every branch.
- **Don't let our slowness block your merge.** `fail-on-timeout: false` turns an overrun into a warning, while a genuine check failure still fails the build.
- **Cancel superseded runs.** A `concurrency` group stops an old push from holding a runner while a newer one is already testing the same branch. The action cancels the Roark run too, so the abandoned simulation stops placing calls you would otherwise be billed for.
- **Keep a job-level backstop.** `timeout-minutes` on the job is the last line of defence if the step itself wedges.

```yaml
jobs:
  simulate:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    concurrency:
      group: roark-sim-${{ github.ref }}
      cancel-in-progress: true
    steps:
      - uses: roarkhq/simulation-action@v1
        with:
          api-token: ${{ secrets.ROARK_API_KEY }}
          plan-id: 3a1d5e7c-9b2f-4a6d-8c31-5f7e9d0a2b4c
```

A single failed poll is not a failed build: the action absorbs up to five consecutive
read failures before giving up, so one network blip does not turn the gate red.

## Not using GitHub Actions?

The gate is in the CLI, so any CI can do the same thing:

```bash
npx @roarkanalytics/cli simulation run --plan-id <id>
```

## Getting an API key

Create one in the Roark platform under project settings. It needs permission to run simulations and read their results. Store it as an encrypted repository secret, never in the workflow file.

## License

Apache-2.0
