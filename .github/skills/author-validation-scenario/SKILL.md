---
name: author-validation-scenario
description: "Use when: creating a new Godot validation harness, harness controller, or scenario JSON contract for gameplay, UI, modal, or integration behavior."
---

# Author Validation Scenario

## Goal

Add a new host-project validation scenario using the packaged runtime without expanding the verifier API unnecessarily.

## Steps

1. Identify the behavior to validate and define the done contract.
2. Add or update a deterministic harness scene under `validation/harnesses/`.
3. Add or update a harness controller under `validation/scripts/harness_controllers/`.
4. Expose semantic state through `get_observed_state()`.
5. Write the scenario JSON under `validation/scenarios/`.
6. Use `assert_value` for direct state checks.
7. Use `assert_pipeline` for derived values and contract-sourced thresholds.
8. Run the scenario and inspect the artifacts.

## Rules

- Prefer richer harness state over new verifier operations.
- Use `signals` when emission behavior matters.
- Use multiple checkpoints around important interaction boundaries.
- Keep host-specific assumptions out of the reusable addon runtime.

## Scenario JSON Schema

Required top-level fields:

| Field | Description |
|---|---|
| `scenario_id` | Stable ID used for artifact folder naming and summaries |
| `version` | Schema version (current: `3`) |
| `description` | Human-readable description of what the scenario validates |
| `harness_scene` | `res://` path to the harness scene |
| `done_contract` | Machine-readable thresholds and expectations for verifier rules |
| `artifact_contract` | `{ required_files: [...], missing_file_is_failure: true }` |
| `exit_codes` | `{ pass: 0, assertion_failure: 1, runtime_error: 2, timeout: 3, artifact_generation_error: 4 }` |
| `cli_contract` | Command template for the local runner |
| `steps` | Ordered array of step operation objects |

## Step Operations Reference

| Op | Shape | Notes |
|---|---|---|
| `load_harness` | `{ op, scene }` | Loads harness scene; calls `reset_harness()` if exposed |
| `checkpoint` | `{ op, name }` | Captures summary, scene tree, event log, screenshot |
| `press_action` | `{ op, action }` | Synthetic InputEventAction press |
| `release_action` | `{ op, action }` | Synthetic InputEventAction release |
| `wait_frames` | `{ op, frames }` | Waits exact number of physics frames |
| `assert_value` | `{ op, checkpoint, path, comparator, expected }` | Direct value check against checkpoint data |
| `assert_pipeline` | `{ op, sources, pipeline, assert }` | Derived value check with named sources and transforms |
| `quit` | `{ op }` | Stops execution, triggers final artifact validation |

## Comparators

`eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `contains`, `starts_with`, `ends_with`

## Pipeline Details

**Source kinds:** `checkpoint` (`checkpoint` + `path`), `contract` (`path`), `literal` (`value`).
**Pipeline ops:** `add`, `subtract`, `abs` — each takes `inputs` (array) and `as` (output name).
**Assert shape:** `{ actual, comparator, expected_source }` or `{ actual, comparator, expected }` for a literal.

## Harness Controller Pattern

File locations: `validation/harnesses/<name>.tscn`, `validation/scripts/harness_controllers/<name>_controller.gd`

A harness controller exposes two methods:

- **`reset_harness()`** — resets all relevant state for a clean run.
- **`get_observed_state()`** — returns a dictionary with semantic game state:

```gdscript
func get_observed_state() -> Dictionary:
    return {
        "nodes": { "player": { "visible": true, "position": player.global_position } },
        "metrics": { "distance_moved": _calc_distance() },
        "signals": { "player": { "died": { "count": 0, "connected": true,
            "signal_name": "died", "source_path": "/root/.../Player", "last_emitted_msec": 0 } } }
    }
```

## Compact Examples

```json
// assert_value — direct checkpoint check
{ "op": "assert_value", "checkpoint": "after",
  "path": "harness_state.nodes.pause_menu.visible", "comparator": "eq", "expected": true }

// assert_pipeline — derived value with contract threshold
{ "op": "assert_pipeline",
  "sources": {
    "before_y":  { "kind": "checkpoint", "checkpoint": "before", "path": "harness_state.actor_position.y" },
    "after_y":   { "kind": "checkpoint", "checkpoint": "after",  "path": "harness_state.actor_position.y" },
    "threshold": { "kind": "contract", "path": "done_contract.min_upward_delta_pixels" }
  },
  "pipeline": [{ "op": "subtract", "inputs": ["before_y", "after_y"], "as": "upward_delta" }],
  "assert": { "actual": "upward_delta", "comparator": "gte", "expected_source": "threshold" }
}
```
