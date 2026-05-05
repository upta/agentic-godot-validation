---
applyTo: "addons/agentic_godot_validation/**"
description: "Use when editing the reusable Godot validation runtime, addon integration templates, or package-owned support code."
---

- Keep runtime code portable across host projects.
- Do not hardcode the bundled example project into framework APIs.
- If a behavior differs by host project, prefer configuration, templates, or host adapters over framework branching.
- Preserve the generic scenario contract and artifact contract unless the docs are updated in the same change.
- Keep package-owned code independent from project-specific gameplay scenes and scripts.
