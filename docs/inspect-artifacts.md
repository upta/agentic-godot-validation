# Inspect Artifacts

## Single Scenario Artifacts

A scenario run writes artifacts under:

`artifacts/<scenario_id>/<timestamp>/`

The most important files are:

- `summary.json`
- `event_log.json`
- `scene_tree.json`
- `console.log`
- checkpoint screenshots

## Where To Start

1. Read `summary.json`
2. Check `failed_assertion` if present
3. Compare the related checkpoints and screenshots
4. Use `event_log.json` to understand step order and timing
5. Use `scene_tree.json` when the runtime shape is suspicious

## Suite Artifacts

A batch run writes:

- `artifacts/suites/<timestamp>/suite.json`
- `artifacts/latest_suite.json`
- `artifacts/suites/index.json`

These record:

- per-iteration results
- per-scenario aggregates
- failed scenario ids
- flaky scenario ids when repeat mode finds inconsistent outcomes

## Practical Debug Flow

- Start with the latest suite manifest if the failure happened during a batch run
- Open the failing scenario's `summary.json`
- Inspect `failed_assertion.related_screenshots`
- Check `signals` and `nodes` inside the relevant checkpoint's `harness_state`
- Only after the artifacts are clear should you change code
