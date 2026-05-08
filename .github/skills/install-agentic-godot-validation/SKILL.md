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
8. If the host project uses Squad (`.squad/` exists), create skill symlinks (see below).

## Squad Skill Symlinks

When the host project has a `.squad/` directory, create symlinks so sub-agents can read validation skills directly:

```powershell
# From the host project root:
New-Item -ItemType Directory -Path .squad/skills -Force

# For each validation skill:
New-Item -ItemType Junction `
  -Path .squad/skills/author-validation-scenario `
  -Target submodules/agentic_godot_validation/.github/skills/author-validation-scenario

New-Item -ItemType Junction `
  -Path .squad/skills/debug-validation-failure `
  -Target submodules/agentic_godot_validation/.github/skills/debug-validation-failure

New-Item -ItemType Junction `
  -Path .squad/skills/install-agentic-godot-validation `
  -Target submodules/agentic_godot_validation/.github/skills/install-agentic-godot-validation
```

This is needed because sub-agents spawned via the `task` tool cannot use the `skill` tool — they can only read files from the filesystem.

## Checks

- The host project still owns its own main scene.
- The addon runtime is not edited just to fit one host project.
- The first scenario writes `summary.json`, `event_log.json`, `scene_tree.json`, `console.log`, and the required screenshots.
- If Squad is in use, `.squad/skills/` symlinks resolve to the submodule skill directories.
