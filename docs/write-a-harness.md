# Write A Harness

## Goal

A harness creates a deterministic, minimal scene for one interaction so validation can focus on the behavior you care about instead of the whole game.

## Preferred Shape

Place harness assets under:

- `validation/harnesses/`
- `validation/scripts/harness_controllers/`

A harness controller should usually expose:

- `reset_harness()`
- `get_observed_state()`

## What `get_observed_state()` Should Return

Prefer semantic data over raw engine internals.

Common fields:

- `nodes` for reusable node facts
- `metrics` for derived numeric values
- `signals` for signal counts and metadata
- any interaction-specific booleans or paths that make assertions clearer

Prefer the shared support helpers in `addons/agentic_godot_validation/runtime/support/` instead of creating verifier-specific shortcuts.

## Practical Rules

- Keep the scene small and reproducible
- Reset all relevant state in `reset_harness()`
- Expose facts that make assertions declarative
- Keep game logic in the host game code, not in the harness controller
- Keep harness controllers project-specific; do not push host-specific assumptions into the reusable runtime
