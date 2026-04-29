# Artifact Schema

The runtime loop writes artifacts into `artifacts/<scenario_id>/<timestamp>/`.

## Required Files

- `summary.json`
- `event_log.json`
- `scene_tree.json`
- `console.log`
- `screenshots/before.png`
- `screenshots/after.png`

Missing any required file is a failed run.

## `summary.json`

High-level run outcome plus the current checkpoint state.

Expected top-level fields:

- `scenario_id`
- `scenario_version`
- `scenario_path`
- `artifacts_dir`
- `status`
- `exit_code`
- `message`
- `started_unix_time`
- `elapsed_msec`
- `current_scene_path`
- `current_scene_name`
- `done_contract`
- `artifact_contract`
- `steps`
- `checkpoints`
- `failed_assertion`
- `errors`
- `warnings`
- `event_count`
- `result`

The `result` object is the verifier-facing outcome. For the current POC scenarios it commonly includes:

- final `status`
- final `exit_code`
- `physics_frames`
- `loaded_harness_path`
- `artifact_presence`
- `runtime_errors`
- `runtime_warnings`
- `verification`
- `verifications`
- `failed_assertion`

The `verification` object now has two main shapes.

Value assertions commonly include:

- `assertion`
- `checkpoint`
- `path`
- `comparator`
- `expected`
- `observed`
- `related_checkpoints`
- `passed`
- `message`

Pipeline assertions commonly include:

- `assertion`
- `actual`
- `actual_value`
- `comparator`
- `expected`
- `expected_source`
- `sources`
- `computed_values`
- `pipeline_results`
- `related_checkpoints`
- `passed`
- `message`

`failed_assertion` is a failure-first summary block surfaced both at the top level and inside `result` when the run stops on an assertion-related failure. It includes:

- `step_index`
- `step_op`
- `assertion`
- `message`
- `checkpoint`
- `path`
- `actual`
- `comparator`
- `expected`
- `expected_source`
- `observed`
- `related_checkpoints`
- `related_screenshots`

Harness state may also include reusable semantic maps such as:

- `harness_state.nodes.<alias>` for node facts like visibility, focus, enabled state, text, and path.
- `harness_state.metrics.<name>` for derived numeric facts such as displacement or distance.
- `harness_state.signals.<alias>.<signal_alias>` for signal facts like emission count and last emission time.

## `event_log.json`

Ordered step execution log with frame numbers.

Expected top-level fields:

- `scenario_id`
- `events`

Each event includes:

- `event`
- `physics_frame`
- `relative_time_msec`
- `details`

## `scene_tree.json`

Scene tree snapshots keyed by checkpoint name and final state.

Expected top-level fields:

- `scenario_id`
- `snapshots`

Each snapshot node includes:

- `name`
- `type`
- `path`
- `children`

Canvas and node types may also add:

- `visible_in_tree`
- `global_position`

## `console.log`

Raw Godot stdout and stderr written by the PowerShell wrapper through `--log-file`.

## Screenshots

- `screenshots/before.png` is captured at the `before` checkpoint.
- `screenshots/after.png` is captured at the `after` checkpoint.

## Manifest Files

The pruning tool also maintains discovery manifests for local iteration.

### `artifacts/index.json`

Expected top-level fields:

- `updated_utc`
- `kept_latest_per_scenario`
- `scenarios`

Each `scenarios.<scenario_id>` entry includes:

- `scenario_id`
- `artifact_dir`
- `run_count`
- `latest`

### `artifacts/<scenario_id>/latest.json`

Per-scenario shortcut to the latest retained run.

Expected fields:

- `scenario_id`
- `artifact_dir`
- `run_count`
- `latest.run_id`
- `latest.artifact_path`
- `latest.summary_path`
- `latest.console_log_path`
- `latest.status`
- `latest.exit_code`
- `latest.message`
- `latest.created_utc`
- `latest.last_write_utc`

### `artifacts/suites/<timestamp>/suite.json`

Structured summary for a single batch suite invocation.

Expected top-level fields:

- `suite_run_id`
- `suite_artifact_path`
- `suite_summary_path`
- `scenario_directory`
- `repeat_count`
- `iteration_count`
- `suite_status`
- `final_exit_code`
- `scenario_count`
- `total_scenario_runs`
- `passed_count`
- `failed_count`
- `passed_iteration_count`
- `failed_iteration_count`
- `flaky_scenario_ids`
- `failed_scenario_ids`
- `keep_latest_per_scenario`
- `keep_latest_suite_runs`
- `started_utc`
- `completed_utc`
- `elapsed_msec`
- `scenario_aggregate`
- `iterations`

Each `scenario_aggregate` entry includes:

- `scenario_id`
- `scenario_file`
- `run_count`
- `pass_count`
- `fail_count`
- `final_exit_codes`
- `statuses`
- `latest_result`
- `flaky`
- `failed`

Each `iterations[*]` entry includes:

- `iteration`
- `scenario_count`
- `passed_count`
- `failed_count`
- `final_exit_code`
- `scenarios`

### `artifacts/suites/index.json`

Retained suite run history after pruning.

Expected fields:

- `updated_utc`
- `keep_latest_suite_runs`
- `suite_root_dir`
- `run_count`
- `latest`
- `runs`

### `artifacts/latest_suite.json`

Top-level shortcut to the latest retained suite run.

Expected fields:

- `updated_utc`
- `keep_latest_suite_runs`
- `suite_root_dir`
- `run_count`
- `latest`

## Local Retention

The local PowerShell tooling prunes artifacts to keep the artifact tree bounded during iterative development.

- `tools/run_scenario.ps1` keeps the latest `10` runs per active scenario by default.
- `tools/prune_artifacts.ps1` removes artifact directories for scenario ids that no longer exist under `test/scenarios/`.
- `tools/prune_artifacts.ps1` rebuilds `artifacts/index.json` and `artifacts/<scenario_id>/latest.json` after pruning.
- `tools/prune_artifacts.ps1` also keeps the latest suite runs under `artifacts/suites/` and rebuilds `artifacts/suites/index.json` plus `artifacts/latest_suite.json`.
- Use `tools/run_scenario.ps1 -SkipArtifactPrune` to keep all generated runs temporarily.
- Use `tools/prune_artifacts.ps1 -KeepLatestPerScenario <n>` to rebalance retention manually.
- Use `tools/prune_artifacts.ps1 -KeepLatestSuiteRuns <n>` to rebalance retained suite runs manually.
- Use `tools/run_all_scenarios.ps1 -RepeatCount <n>` to run soak or repeat passes and record flakiness in a retained suite artifact.

