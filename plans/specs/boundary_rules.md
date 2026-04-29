# Boundary Rules

These rules are normative for the repository layout introduced in steps 1 through 4.

## Directory Responsibilities

- `game/` contains shipped gameplay scenes, scripts, and future resources.
- `test/` contains validation-only harnesses, bootstrap logic, drivers, inspectors, and scenarios.
- `bootstrap/` contains neutral project entry infrastructure that may choose between production and test mode, but it must not contain gameplay rules or validation assertions.
- `artifacts/` is reserved for generated runtime evidence and must stay out of normal project content and exports.

## Dependency Direction

- `test/` may load scenes and scripts from `game/`.
- `game/` must never import, instantiate, call, or reference anything under `test/`.
- `bootstrap/` may route into either side because it exists outside both roots.
- If logic needs to be shared later, place it in a neutral location rather than introducing a `game -> test` dependency.

## Determinism And Observability

- Test-mode determinism setup belongs in `test/scripts/bootstrap/test_bootloader.gd`.
- Gameplay scripts stay free of test-only branches.
- The test layer may observe gameplay through public methods, node state, transforms, and signals.
- The first harness must instance the production player scene from `game/` instead of duplicating movement logic under `test/`.
