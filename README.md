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

**One global threshold** decides the run, and its rate is a weighted combination of your checks. Each metric carries a `weight`, so you decide how much each one counts:

| Check | Passed | Rate | Weight |
|---|---|---|---|
| agent containment | 30/50 | 60% | 50 |
| latency | 20/50 | 40% | 12 |
| response time | 32/50 | 64% | 88 |

`(50x60 + 12x40 + 88x64) / 150` = **60.7%** against your global threshold.

Weights are **relative**, so they need not sum to anything: `50/12/88` and `25/6/44` mean the same thing. Leave them alone and every check counts equally. Set one to `0` to keep a check reported but out of the global rate.

Two modes:

| Mode | The question it answers |
|---|---|
| `WEIGHTED` | "Is the mix I care about healthy?" — weighted mean of each check's rate. |
| `OVERALL` | "Were most verdicts good?" — every (check, call) verdict counted once, so busier checks weigh more. |

On top of the global threshold, any metric can carry its **own floor** (*"latency must clear 12% whatever the global rate says"*). Both must hold.

A run **fails** when it did not complete, when a check you gated on never ran, when some calls dropped out of scoring, or when any rate is below its minimum. None of those pass silently.

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
    weight: 50
  - slug: latency
    weight: 12
    successMinPassRate: 12         # this check's own floor, whatever the global rate
  - slug: leaked_pii
    weight: 88
    expectedBooleanValue: false    # this check passes when the answer is FALSE
ciGate:
  enabled: true
  mode: WEIGHTED
  minPassRate: 90
```

```yaml
      - uses: actions/checkout@v4
      - uses: roarkhq/simulation-action@v1
        with:
          api-token: ${{ secrets.ROARK_API_KEY }}
          config: .roark/checkout-regression.yml
```

This runs as a one-off: nothing is added to your saved plans.

### Hold one branch to a higher bar

`min-pass-rate` overrides the minimum for this pipeline only, leaving the shared plan alone:

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
| `min-pass-rate` | no | | Override the minimum pass rate (0-100) for this pipeline. |
| `timeout-minutes` | no | `30` | How long to wait for the run. |
| `poll-interval-seconds` | no | `15` | How often to check for completion. |
| `fail-on-timeout` | no | `true` | `false` warns instead of failing when the run overruns. |
| `cli-version` | no | pinned | Version of `@roarkanalytics/cli` to run. |
| `api-base-url` | no | `https://api.roark.ai` | Override the API base URL. |

## Outputs

| Output | Description |
|---|---|
| `run-id` | The simulation run id. |
| `run-url` | Link to the run in the Roark platform. |
| `pass-rate` | The pass rate the gate judged, 0-100. |
| `verdict` | `PASSED`, `FAILED`, or `TIMED_OUT`. |

## Simulations take minutes

Real calls take real time, so a gated run occupies a runner while it waits. Two ways to keep that cheap:

- **Run it where it matters.** Gate `main` or your release branch rather than every push to every branch.
- **Don't let our slowness block your merge.** `fail-on-timeout: false` turns an overrun into a warning, while a genuine check failure still fails the build.

## Not using GitHub Actions?

The gate is in the CLI, so any CI can do the same thing:

```bash
npx @roarkanalytics/cli simulation run --plan-id <id>
```

## Getting an API key

Create one in the Roark platform under project settings. It needs permission to run simulations and read their results. Store it as an encrypted repository secret, never in the workflow file.

## License

Apache-2.0
