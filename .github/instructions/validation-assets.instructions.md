---
applyTo: "validation/**,examples/minimal_poc/validation/**"
description: "Use when editing host-owned validation harnesses, harness controllers, or scenario contracts."
---

- Keep harnesses deterministic and minimal.
- Expose semantic runtime facts through `get_observed_state()`.
- Prefer reusable `nodes`, `metrics`, and `signals` facts over verifier-specific shortcuts.
- Keep project-specific logic in host validation assets instead of moving it into the reusable addon runtime.
- Prefer `assert_value` and `assert_pipeline` over new bespoke scenario operations.
