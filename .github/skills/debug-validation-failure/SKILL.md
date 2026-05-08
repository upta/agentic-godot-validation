---
name: debug-validation-failure
description: "Use when: diagnosing a failing Godot validation scenario or suite run by reading summary.json, event logs, scene trees, screenshots, and signal facts."
---

# Debug Validation Failure

## Goal

Use generated artifacts to diagnose runtime behavior before changing code.

## Steps

1. Start with `artifacts/latest_suite.json` if the failure came from a batch run.
2. Open the relevant scenario `summary.json`.
3. Inspect `failed_assertion` and note related checkpoints and screenshots.
4. Compare the relevant checkpoint `harness_state` fields.
5. Read `event_log.json` for step order and frame timing.
6. Read `scene_tree.json` if the runtime shape or node ownership is suspicious.
7. Only after the artifacts are clear should you patch code.

## Focus Areas

- visibility and focus mismatches
- missing or repeated signals
- modal input suppression leaks
- wrong harness state exposure
- artifact contract failures
- flaky scenarios revealed by suite repeat mode

## Artifact Locations

Artifacts are written to: `artifacts/<scenario_id>/<timestamp>/`

Shortcut files for latest runs:
- `artifacts/<scenario_id>/latest.json` — per-scenario latest run pointer
- `artifacts/index.json` — cross-scenario index
- `artifacts/latest_suite.json` — latest batch suite pointer
- `artifacts/suites/<timestamp>/suite.json` — full suite summary

## Reading summary.json

Key fields to check first:

| Field | What to look for |
|---|---|
| `status` / `exit_code` | Overall pass/fail. Exit codes: 0=pass, 1=assertion_failure, 2=runtime_error, 3=timeout, 4=artifact_error |
| `failed_assertion` | Failure-first block with `step_index`, `step_op`, `message`, `checkpoint`, `path`, `actual`/`observed`, `comparator`, `expected`, `related_checkpoints`, `related_screenshots` |
| `checkpoints` | Map of checkpoint names → captured state. Each contains `harness_state` with `nodes`, `metrics`, `signals` |
| `errors` / `warnings` | Runtime errors and warnings collected during the run |
| `result.verifications` | Array of all assertion results (both passed and failed) |

For value assertions in `verifications`: check `checkpoint`, `path`, `comparator`, `expected`, `observed`, `passed`.
For pipeline assertions: check `actual_value`, `comparator`, `expected`, `sources`, `computed_values`, `pipeline_results`, `passed`.

## Reading event_log.json

Structure: `{ scenario_id, events: [...] }`

Each event: `{ event, physics_frame, relative_time_msec, details }`

Look for: step execution order matching the scenario, unexpected frame gaps between steps, steps that never executed (truncated log = crash or timeout).

## Reading scene_tree.json

Structure: `{ scenario_id, snapshots: { "<checkpoint_name>": {...}, "final": {...} } }`

Each node: `{ name, type, path, children, visible_in_tree?, global_position? }`

Look for: missing nodes (harness not loaded), wrong node types, unexpected hierarchy, nodes not visible when they should be.

## Signal Facts Shape

Signal probes in `harness_state.signals.<alias>.<signal_alias>` expose:

| Field | Description |
|---|---|
| `count` | Number of times the signal was emitted |
| `connected` | Whether the probe is connected |
| `signal_name` | Godot signal name being tracked |
| `source_path` | Node path of the signal source |
| `last_emitted_msec` | Timestamp of last emission (0 if never) |

## Common Failure Patterns

| Symptom | Diagnostic Steps |
|---|---|
| **Wrong observed value** | Check `harness_state` in the checkpoint — is `get_observed_state()` returning what you expect? |
| **Checkpoint missing** | Check event_log — did the checkpoint step execute? Scene may have crashed before reaching it. |
| **Node not found** | Check scene_tree — is the node in the tree? Check the harness scene for correct paths. |
| **Signal count 0** | Verify signal probe is connected (`connected: true`). Check if the action that triggers the signal actually ran. |
| **Timeout (exit 3)** | Check `done_contract.frame_budget` and `wait_frames` totals. Look at event_log for the last executed step. |
| **Flaky results** | Run with `-RepeatCount 5`. Compare checkpoints across runs. Usually a timing or initialization-order issue. |
| **Artifact missing** | Check `artifact_contract.required_files` vs actual files on disk. Check console.log for screenshot errors. |
