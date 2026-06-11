# Scenario Format

The current scenario format is a JSON object executed entirely inside Godot by `addons/agentic_godot_validation/runtime/drivers/scenario_driver.gd`.

## Required Top-Level Fields

- `scenario_id`: stable identifier for artifact folder naming and summaries.
- `version`: schema version for the scenario file.
- `description`: human-readable scenario description.
- `harness_scene`: default harness scene path under `res://validation/harnesses/` in a host project.
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
  "scene": "res://validation/harnesses/movement_harness.tscn"
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

### `wait_until`

Polls the harness's live `get_observed_state()` until a condition holds, or fails with `assertion_failure` when `timeout_frames` physics frames elapse. Use this instead of `wait_frames` whenever the wait depends on nondeterministic timing (network round-trips, deferred spawns, async loads).

```json
{
  "op": "wait_until",
  "path": "harness_state.connection.player_count",
  "comparator": "gte",
  "expected": 2,
  "timeout_frames": 300,
  "poll_every_frames": 1
}
```

Rules:

- `path` resolves against a live sample shaped `{ "harness_state": <get_observed_state()> }`, so paths use the same `harness_state.` prefix as checkpoint assertions.
- The condition is evaluated immediately (frame 0) and then every `poll_every_frames` (default 1) physics frames.
- `timeout_frames` defaults to 300 (5 seconds at 60 TPS) and must be positive.
- A path that does not resolve yet, or a comparator/type mismatch, counts as "not yet" and keeps polling — live state may legitimately appear later. Only an unsupported comparator name is an immediate runtime error.
- On success, the verification records `frames_waited` and the final observed value.
- On timeout, the runtime captures a debug checkpoint named `wait_until_timeout_step_<index>` (including a screenshot) and fails with the last observed value as evidence.

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

## Packaging Note

- In a consuming project, scenarios belong under `validation/scenarios/` and harness scenes belong under `validation/harnesses/`.
- This package repository keeps its bundled reference scenarios under `examples/minimal_poc/validation/scenarios/` so the example project does not define the reusable host layout.

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
- `total_wait_frames` is the sum of all `wait_frames` steps' `frames` plus all `wait_until` steps' `timeout_frames` (default 300).
- `frame_budget` and `physics_ticks_per_second` come from `done_contract`.
