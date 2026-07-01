# Runs both validation suites: pure client scenarios, then SpacetimeDB-backed scenarios against an
# ephemeral local database. Fails if either suite fails. All paths come from the consumer repo's
# validation.config.psd1 (via validation_config.ps1).
#
# Both suites run in parallel by default (pure: 4-wide; STDB: 2-wide, since all clients share one
# local server). Override per suite with -PureMaxParallel / -StdbMaxParallel; pass 1 for a fully
# serial run when debugging.
#
# Re-run policy differs by suite ON PURPOSE: the pure (CPU-only) suite FORGIVES a scenario that
# fails in parallel but passes its serial re-run (environmental flake -> green); the STDB suite
# stays STRICT (a parallel networked failure is the load-sensitive regression it exists to catch).

param(
    [string]$GodotExe = $env:GODOT_EXE,
    [int]$PureMaxParallel = 0,   # 0 = use run_all_scenarios.ps1 default
    [int]$StdbMaxParallel = 0,   # 0 = use run_stdb_scenarios.ps1 default
    [switch]$Record,
    [int]$RecordFps = 30,
    [switch]$NoRerun
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot "validation_config.ps1")
$config = Import-ValidationConfig -RepoRoot $repoRoot

# High-water mark of the timing log BEFORE the suites run, so the end-of-run summary shows only
# THIS run's records.
$statsLog = Join-Path $config.ArtifactsDir "stats/test_timings.jsonl"
$statsPriorCount = if (Test-Path $statsLog) { @(Get-Content $statsLog).Count } else { 0 }

# Skip a tier that has no scenarios yet (e.g. a networked-only project with only scenarios_stdb, or
# vice versa) instead of failing — an empty tier is a no-op pass, not a suite failure.
$pureDir = Join-Path $config.ClientDir "validation/scenarios"
$purePresent = (Test-Path $pureDir) -and (@(Get-ChildItem $pureDir -Filter *.json -File -ErrorAction SilentlyContinue).Count -gt 0)
if ($purePresent) {
    Write-Host "=== Pure validation suite ($($config.ClientRoot)/validation/scenarios) ===" -ForegroundColor Cyan
    # Pure-suite policy is forgive: a scenario that fails the parallel pass but passes the serial
    # re-run is environmental here, so it's treated as passed. STDB stays strict in its own runner.
    $pureArgs = @{ GodotExe = $GodotExe; RerunVerdict = "forgive"; ProjectPath = $config.ClientDir }
    if ($PureMaxParallel -gt 0) { $pureArgs.MaxParallel = $PureMaxParallel }
    if ($Record) { $pureArgs.Record = $true; $pureArgs.RecordFps = $RecordFps }
    if ($NoRerun) { $pureArgs.NoRerun = $true }
    & (Join-Path $PSScriptRoot "run_all_scenarios.ps1") @pureArgs
    $pureExit = $LASTEXITCODE
}
else {
    Write-Host "=== Pure validation suite — no scenarios under $($config.ClientRoot)/validation/scenarios, skipping ===" -ForegroundColor DarkYellow
    $pureExit = 0
}

Write-Host "=== SpacetimeDB validation suite ($($config.ScenariosStdbDir)) ===" -ForegroundColor Cyan
$stdbArgs = @{ GodotExe = $GodotExe }
if ($StdbMaxParallel -gt 0) { $stdbArgs.MaxParallel = $StdbMaxParallel }
if ($Record) { $stdbArgs.Record = $true; $stdbArgs.RecordFps = $RecordFps }
if ($NoRerun) { $stdbArgs.NoRerun = $true }
& (Join-Path $PSScriptRoot "run_stdb_scenarios.ps1") @stdbArgs
$stdbExit = $LASTEXITCODE

Write-Host ""
Write-Host ("Pure suite: " + $(if ($pureExit -eq 0) { "PASS" } else { "FAIL ($pureExit)" }))
Write-Host ("STDB suite: " + $(if ($stdbExit -eq 0) { "PASS" } else { "FAIL ($stdbExit)" }))

# Combined re-run + timing readout for THIS run.
if (Test-Path $statsLog) {
    $recs = @(Get-Content $statsLog | Select-Object -Skip $statsPriorCount | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
    Write-Host ""
    Write-Host "=== Re-run + timing (this run) ===" -ForegroundColor Cyan
    foreach ($suiteName in @("pure", "stdb")) {
        $r = $recs | Where-Object { $_.suite -eq $suiteName } | Select-Object -Last 1
        if ($null -ne $r) {
            $recovered = @($r.recovered_on_rerun).Count
            $failedBoth = @($r.failed_both).Count
            Write-Host ("  {0,-4} {1}-wide: parallel {2}s + rerun {3}s = {4}s | recovered {5} | failed_both {6} -> {7}" -f `
                    $suiteName, $r.max_parallel, $r.parallel_phase_sec, $r.rerun_phase_sec, $r.total_sec, `
                    $recovered, $failedBoth, ([string]$r.suite_status).ToUpper())
        }
        else {
            Write-Host ("  {0,-4} (no timing record this run)" -f $suiteName) -ForegroundColor DarkYellow
        }
    }
    Write-Host ("  stats: {0}  ·  trend: ./tools/aggregate_test_timings.ps1 -ArtifactsRoot {1}" -f $statsLog, $config.ArtifactsRoot)
}

exit [Math]::Max($pureExit, $stdbExit)
