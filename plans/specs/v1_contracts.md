# V1 Contracts

These contracts are locked for steps 1 through 4 of the v1 plan.

## Scenario Contract

- Scenario id: `move_up_smoke`
- Harness scene: `res://test/harnesses/movement_harness.tscn`
- Controlled actor: `PlayerActor` inside the harness scene
- Initial actor position: `Vector2(640, 360)`
- Input action: `move_up`
- Keyboard source of truth for local manual runs: physical `W` key
- Physics tick rate: `60` ticks per second
- Frame budget: `20` physics frames
- Pass threshold: actor `y` must decrease by at least `48.0` pixels inside the frame budget

The machine-readable source of truth for the same contract is `test/scenarios/move_up_smoke.json`.

The executable step sequence is documented in `plans/specs/scenario_format.md`.

## Artifact Contract

The following files are required for every successful v1 scenario run:

- `summary.json`
- `event_log.json`
- `scene_tree.json`
- `console.log`
- `screenshots/before.png`
- `screenshots/after.png`

Missing any required artifact is an automatic failure.

The runtime artifact shapes are documented in `plans/specs/artifact_schema.md`.

## Exit Code Contract

- `0`: pass
- `1`: assertion failure
- `2`: runtime error
- `3`: timeout
- `4`: artifact generation error

## Bootstrap Contract

- CLI form: `godot --path <project> -- --test-mode --scenario <path> --artifacts <dir>`
- Project entry scene: `res://bootstrap/app_root.tscn`
- Test entry scene: `res://test/bootstrap/test_bootstrap.tscn`
- Production entry scene: `res://game/scenes/main.tscn`

Godot exposes only one `run/main_scene`, so the repository uses a neutral root router under `bootstrap/` to select production or test mode without placing any reverse dependency from `game/` into `test/`.

## Timeout Contract

The v1 timeout is derived from the scenario rather than hard-coded in a separate spec.

- Formula: `max(5.0, max(total_wait_frames, frame_budget) / physics_ticks_per_second + 3.0)`
- `total_wait_frames` comes from the scenario steps.
- `frame_budget` and `physics_ticks_per_second` come from `done_contract`.
