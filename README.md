# Agentic Godot Validation Kit

Reusable deterministic scenario validation for Godot projects.

This repository serves two purposes:

- package source for the reusable runtime under `addons/agentic_godot_validation/`
- runnable development shell with a bundled reference project under `examples/minimal_poc/`

## What To Copy Into Another Project

Copy these paths into a host Godot project:

- `addons/agentic_godot_validation/`
- `tools/`
- `validation/`
- optionally `.github/`
- optionally `docs/`

Do not treat `examples/minimal_poc/` as framework code. It is sample content only.

## Host Layout

Expected host-owned validation layout:

- `validation/harnesses/`
- `validation/scripts/harness_controllers/`
- `validation/scenarios/`

The runtime prefers host scenarios under `validation/scenarios/`. In this repository only, the tools fall back to `examples/minimal_poc/validation/scenarios/` so the bundled sample remains runnable.

## Runtime Entry Point

Host projects should route test mode to:

- `res://addons/agentic_godot_validation/runtime/scenes/test_bootstrap.tscn`

Use the template router under `addons/agentic_godot_validation/integration/templates/` as a starting point, not as mandatory framework-owned app structure.

## Docs

- `docs/package-layout.md`
- `docs/install-into-existing-project.md`
- `docs/host-integration.md`
- `docs/write-a-harness.md`
- `docs/write-a-scenario.md`
- `docs/inspect-artifacts.md`

## Bundled Validation Check

Run the bundled example suite with:

```powershell
./tools/run_all_scenarios.ps1 -GodotExe <path-to-godot.exe>
```