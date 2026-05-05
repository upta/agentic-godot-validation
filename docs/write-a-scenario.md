# Write A Scenario

Scenario contracts are JSON files stored under `validation/scenarios/` in a consuming project.

## Core Shape

Each scenario defines:

- a stable `scenario_id`
- a `harness_scene`
- a `done_contract`
- an `artifact_contract`
- a list of `steps`

## Current Assertion Model

Use:

- `assert_value` for direct checkpoint reads
- `assert_pipeline` for named-source and contract-sourced derived checks

Avoid adding bespoke verifier ops unless the generic model truly breaks down.

## Preferred Patterns

- capture checkpoints around interaction boundaries
- expose semantic harness state instead of hardcoding verifier knowledge
- use contract values instead of repeating thresholds as literals
- use signal facts when emission behavior is the real contract

## Run Commands

Single scenario:

```powershell
./tools/run_scenario.ps1 -Scenario validation/scenarios/<scenario>.json -GodotExe <path-to-godot.exe>
```

Full suite:

```powershell
./tools/run_all_scenarios.ps1 -GodotExe <path-to-godot.exe>
```

Repeat mode:

```powershell
./tools/run_all_scenarios.ps1 -GodotExe <path-to-godot.exe> -RepeatCount 5
```

## Normative Specs

For the full schema, see:

- `plans/specs/scenario_format.md`
- `plans/specs/artifact_schema.md`
