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
