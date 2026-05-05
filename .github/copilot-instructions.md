# Copilot Instructions

This repository packages a reusable Godot validation kit.

## Package Boundary

- Keep portable runtime code under `addons/agentic_godot_validation/`
- Keep host-project validation assets under `validation/`
- Keep bundled sample content under `examples/minimal_poc/`
- Do not move example-specific assumptions back into the reusable runtime

## Runtime Rules

When editing `addons/agentic_godot_validation/`:

- prefer host-agnostic behavior
- avoid hardcoding bundled example paths except in documented fallback discovery lists
- preserve the generic `assert_value` and `assert_pipeline` model
- preserve suite artifact and retention contracts unless the docs are updated with the change

## Validation Asset Rules

When editing host validation assets:

- expose semantic state through harness controllers
- prefer `nodes`, `metrics`, and `signals` under `harness_state`
- do not add project-specific verifier operations if harness state can express the contract

## Packaging Mindset

This repo is both a package source and a runnable development shell. Keep the root runnable while making the addon portable.
