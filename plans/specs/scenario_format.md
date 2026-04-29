# Scenario Format

The current scenario format is a JSON object executed entirely inside Godot by `test/scripts/drivers/scenario_driver.gd`.

## Required Top-Level Fields

- `scenario_id`: stable identifier for artifact folder naming and summaries.
- `version`: schema version for the scenario file.
- `description`: human-readable scenario description.
- `harness_scene`: default harness scene path under `res://test/harnesses/`.
- `done_contract`: machine-readable thresholds and expectations used by verifier rules.
- `artifact_contract`: required artifact files that must exist after the run.
- `exit_codes`: scenario exit code mapping.
- `cli_contract`: the canonical CLI form for the local runner.
- `steps`: ordered list of executable step objects.

## Supported Step Operations

### `load_harness`

Loads the harness scene for the run and resets it if the harness exposes `reset_harness()`.

```json
{
  "op": "load_harness",
  "scene": "res://test/harnesses/movement_harness.tscn"
}
```

### `checkpoint`

Captures a runtime checkpoint. The inspector writes or refreshes `summary.json`, `scene_tree.json`, `event_log.json`, and `screenshots/<name>.png`.

```json
{
  "op": "checkpoint",
  "name": "before"
}
```

### `press_action`

Dispatches a synthetic `InputEventAction` press for a Godot input action.

```json
{
  "op": "press_action",
  "action": "move_up"
}
```

### `release_action`

Dispatches a synthetic `InputEventAction` release for a Godot input action.

```json
{
  "op": "release_action",
  "action": "move_up"
}
```

### `wait_frames`

Waits an exact number of physics frames.

```json
{
  "op": "wait_frames",
  "frames": 20
}
```

### `assert_value`

Evaluates a single value already captured in a checkpoint using a dot-path resolver and comparator. Keep using this for direct point checks that do not need contract-sourced math.

```json
{
  "op": "assert_value",
  "checkpoint": "after",
  "path": "harness_state.nodes.pause_menu.visible",
  "comparator": "eq",
  "expected": true
}
```

### `assert_pipeline`

Evaluates named sources, optional pipeline transforms, and a final comparator. Use this when the asserted value should be derived from multiple checkpoints or sourced from the contract instead of repeated as a literal.

```json
{
  "op": "assert_pipeline",
  "sources": {
    "before_y": {
      "kind": "checkpoint",
      "checkpoint": "before",
      "path": "harness_state.actor_position.y"
    },
    "after_y": {
      "kind": "checkpoint",
      "checkpoint": "after",
      "path": "harness_state.actor_position.y"
    },
    "threshold": {
      "kind": "contract",
      "path": "done_contract.min_upward_delta_pixels"
    }
  },
  "pipeline": [
    {
      "op": "subtract",
      "inputs": ["before_y", "after_y"],
      "as": "upward_delta"
    }
  ],
  "assert": {
    "actual": "upward_delta",
    "comparator": "gte",
    "expected_source": "threshold"
  }
}
```

Supported source kinds in v3:

- `checkpoint`
- `contract`
- `literal`

Supported pipeline operations in v3:

- `add`
- `subtract`
- `abs`

`assert` rules in v3:

- `assert.actual` must reference a named source or pipeline output.
- `assert.comparator` uses the same comparator set as `assert_value`.
- Use either `assert.expected_source` to compare against another named value or `assert.expected` for a literal.

Supported comparators in v3:

- `eq`
- `neq`
- `gt`
- `gte`
- `lt`
- `lte`
- `contains`
- `starts_with`
- `ends_with`

Path and resolution rules in v3:

- `path` is dot-separated and resolves relative to the checkpoint root object or contract root object.
- Numeric array indices are allowed, for example `tracked_nodes.1.path`.
- Missing checkpoints or missing checkpoint paths fail the assertion with explicit evidence.
- Unsupported comparators, malformed pipeline steps, or incompatible comparator/type pairs are treated as scenario runtime errors.

Harness guidance in v3:

- Prefer exposing derived runtime facts through `harness_state` when that keeps assertions declarative.
- Prefer exposing semantic node facts under `harness_state.nodes.<alias>` for reusable UI and scene assertions.
- Prefer exposing reusable signal facts under `harness_state.signals.<alias>.<signal_alias>` when interactions are best validated by emitted signals.
- Signal probes currently expose count-oriented facts such as `count`, `connected`, `signal_name`, `source_path`, and `last_emitted_msec`.

### `quit`

Stops scenario execution and returns control to the bootloader for final artifact validation and process exit.

```json
{
  "op": "quit"
}
```

## Timeout Rule

The bootloader derives the scenario timeout from the scenario itself instead of locking a separate constant.

- Formula: `max(5.0, max(total_wait_frames, frame_budget) / physics_ticks_per_second + 3.0)`
- `total_wait_frames` is the sum of all `wait_frames` steps.
- `frame_budget` and `physics_ticks_per_second` come from `done_contract`.
