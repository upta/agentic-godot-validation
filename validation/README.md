# Validation Root

This directory is intentionally reserved for host-project validation assets.

In a consuming Godot project, add project-specific files here:

- `validation/harnesses/` for deterministic harness scenes
- `validation/scripts/harness_controllers/` for harness controllers and host adapters
- `validation/scenarios/` for scenario JSON contracts

This package repo keeps the runnable reference content under `examples/minimal_poc/validation/` so the reusable runtime and the sample project stay separate.
