---
name: install-agentic-godot-validation
description: "Use when: installing this agentic Godot validation kit into an existing Godot project, wiring test mode, copying addon files, or validating the first scenario run."
---

# Install Agentic Godot Validation

## Goal

Integrate the reusable validation runtime into a host Godot project without copying the bundled sample game as if it were framework code.

## Steps

1. Copy `addons/agentic_godot_validation/` into the host project.
2. Copy `tools/` into the host project root.
3. Create `validation/harnesses/`, `validation/scripts/harness_controllers/`, and `validation/scenarios/`.
4. Add a host test-mode router that can load `res://addons/agentic_godot_validation/runtime/scenes/test_bootstrap.tscn`.
5. Create or copy one minimal harness and one minimal scenario.
6. Run `./tools/run_scenario.ps1 -Scenario validation/scenarios/<scenario>.json -GodotExe <path>`.
7. Confirm the expected artifact bundle is produced.

## Checks

- The host project still owns its own main scene.
- The addon runtime is not edited just to fit one host project.
- The first scenario writes `summary.json`, `event_log.json`, `scene_tree.json`, `console.log`, and the required screenshots.
