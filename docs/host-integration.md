# Host Integration

## Responsibility Split

The host project owns:

- `project.godot`
- the production main scene
- startup routing
- project-specific validation harnesses and scenarios

The package owns:

- the test bootloader
- scenario execution
- runtime inspection
- verification
- artifact generation
- suite execution and retention tooling

## Required Host Wiring

The minimum host contract is:

1. support a `--test-mode` branch in startup
2. route test mode to `res://addons/agentic_godot_validation/runtime/scenes/test_bootstrap.tscn`
3. ensure any required input actions exist
4. store project-specific harnesses and scenarios under `validation/`

## Suggested Startup Pattern

Keep your own production root scene. Add a small host adapter that decides between:

- your normal production scene
- the validation boot scene

The bundled template under `addons/agentic_godot_validation/integration/templates/` is intentionally small so you can adapt it instead of inheriting framework-owned startup logic.

## Path Conventions

The tools prefer these host paths:

- `validation/scenarios/`
- `validation/harnesses/`
- `validation/scripts/harness_controllers/`

In this package repo, the runners fall back to `examples/minimal_poc/validation/` because the bundled example uses that location.
