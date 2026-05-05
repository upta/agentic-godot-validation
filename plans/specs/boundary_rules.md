# Boundary Rules

These rules are normative for the packaged layout introduced in v6.

## Directory Responsibilities

- `addons/agentic_godot_validation/` contains portable validation runtime code, integration templates, and package-owned support assets.
- `validation/` is reserved for host-project validation assets such as harnesses, harness controllers, host adapters, and scenario contracts.
- `examples/minimal_poc/` contains bundled reference gameplay and sample validation content for this repository only.
- `artifacts/` is reserved for generated runtime evidence and suite summaries and must stay out of normal project content and exports.
- `tools/` contains developer-facing command-line runners and artifact maintenance scripts.

## Dependency Direction

- `validation/` may load scenes and scripts from the host project's gameplay code.
- `validation/` may load package-owned runtime support from `addons/agentic_godot_validation/`.
- Host gameplay code must never import, instantiate, call, or reference project-specific assets under `validation/`.
- Package runtime code under `addons/agentic_godot_validation/` must not depend on `examples/minimal_poc/` or on a specific host project's gameplay code.
- Example content under `examples/minimal_poc/` may depend on the package runtime because it is sample content, not the reusable framework.

## Startup And Integration

- The host project owns `project.godot`, its production main scene, and any `--test-mode` routing adapter.
- The package may ship integration templates, but it must not require host projects to adopt a framework-owned root router unchanged.
- Test entry for the runtime is `res://addons/agentic_godot_validation/runtime/scenes/test_bootstrap.tscn`.

## Determinism And Observability

- Test-mode determinism setup belongs in `addons/agentic_godot_validation/runtime/bootstrap/test_bootloader.gd`.
- Gameplay scripts stay free of test-only branches.
- Host validation assets may observe gameplay through public methods, node state, transforms, and signals.
- Harnesses should instance production scenes whenever possible instead of duplicating gameplay logic inside host validation code.
