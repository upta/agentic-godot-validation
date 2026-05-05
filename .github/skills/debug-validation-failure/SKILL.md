---
name: debug-validation-failure
description: "Use when: diagnosing a failing Godot validation scenario or suite run by reading summary.json, event logs, scene trees, screenshots, and signal facts."
---

# Debug Validation Failure

## Goal

Use generated artifacts to diagnose runtime behavior before changing code.

## Steps

1. Start with `artifacts/latest_suite.json` if the failure came from a batch run.
2. Open the relevant scenario `summary.json`.
3. Inspect `failed_assertion` and note related checkpoints and screenshots.
4. Compare the relevant checkpoint `harness_state` fields.
5. Read `event_log.json` for step order and frame timing.
6. Read `scene_tree.json` if the runtime shape or node ownership is suspicious.
7. Only after the artifacts are clear should you patch code.

## Focus Areas

- visibility and focus mismatches
- missing or repeated signals
- modal input suppression leaks
- wrong harness state exposure
- artifact contract failures
- flaky scenarios revealed by suite repeat mode
