# Install Into An Existing Project

## Goal

Copy the reusable validation runtime into another Godot project without adopting the bundled sample game.

## Copy These Parts

From this repo, copy:

- `addons/agentic_godot_validation/`
- `tools/`
- optionally `.github/` if you want the Copilot instructions and skills
- optionally the docs in `docs/`

Do not copy `examples/minimal_poc/` unless you want the sample content as reference.

## Create Host Validation Folders

In the target project, create:

- `validation/harnesses/`
- `validation/scripts/harness_controllers/`
- `validation/scenarios/`

## Wire Test Mode

Choose one of these approaches:

1. Adapt the template at `addons/agentic_godot_validation/integration/templates/host_validation_router.gd` and route `--test-mode` to `res://addons/agentic_godot_validation/runtime/scenes/test_bootstrap.tscn`.
2. Copy the bundled example pattern from `examples/minimal_poc/bootstrap/app_root.gd` and tailor it to your project.

The host project stays responsible for its own main scene and startup flow.

## First Scenario Run

From the host project root, run:

```powershell
./tools/run_scenario.ps1 -Scenario validation/scenarios/<your-scenario>.json -GodotExe <path-to-godot.exe>
```

Or run the whole suite:

```powershell
./tools/run_all_scenarios.ps1 -GodotExe <path-to-godot.exe>
```

## Success Criteria

A healthy setup produces:

- `artifacts/<scenario_id>/<timestamp>/summary.json`
- `artifacts/<scenario_id>/<timestamp>/event_log.json`
- `artifacts/<scenario_id>/<timestamp>/scene_tree.json`
- `artifacts/<scenario_id>/<timestamp>/console.log`
- expected checkpoint screenshots

Use `artifacts/index.json` and `artifacts/latest_suite.json` to inspect the retained latest results.
