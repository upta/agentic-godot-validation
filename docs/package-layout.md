# Package Layout

This repository is organized into three ownership zones.

## Reusable Framework

`addons/agentic_godot_validation/`

This is the portable validation runtime that can be copied into another Godot project. It contains:

- `runtime/` for the bootloader, driver, verifier, inspector, and support utilities
- `integration/templates/` for host-routing examples
- `plugin.cfg` and `plugin.gd` for addon discovery

Framework code should stay host-agnostic.

## Host-Owned Validation Assets

`validation/`

This is where a consuming Godot project places its own harnesses, harness controllers, host adapters, and scenario JSON contracts.

Expected structure:

- `validation/harnesses/`
- `validation/scripts/harness_controllers/`
- `validation/scenarios/`

## Bundled Example Project

`examples/minimal_poc/`

This contains the runnable sample gameplay and validation content that proves the kit works.

It includes:

- `bootstrap/`
- `game/`
- `validation/`

## Tooling And Docs

- `tools/` contains the PowerShell runners and pruning scripts
- `docs/` contains consumer-facing installation and authoring guides
- `.github/` contains Copilot instructions and skills
- `plans/` contains internal evolution history and implementation plans

## Practical Rule

If a file must work unchanged across many Godot projects, it belongs under `addons/agentic_godot_validation/`.
If it describes one specific game, it belongs under that host project's `validation/` or example content.
