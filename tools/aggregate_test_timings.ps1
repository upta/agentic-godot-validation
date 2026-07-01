# Aggregates the append-only validation-timing log (one JSON record per suite run, emitted by
# run_all_scenarios.ps1 and run_stdb_scenarios.ps1 under <ArtifactsRoot>/stats/test_timings.jsonl)
# into a test-timing-report.{json,md} that answers: "is parallel (with reruns) actually gaining
# us anything time-wise?".
#
# Records are bucketed by host x suite x max_parallel (NEVER across hosts — timings are
# machine-specific). Per bucket: run count, median/p10/p90 total wall-clock, median parallel vs
# rerun phase, mean rerun "tax" (rerun / total), and recovery rate (recovered / failed_parallel).
# Speedup is computed within a host x suite as median(total | serial) / median(total | parallel)
# on the rerun-ADJUSTED total, so frequent reruns can't hide behind a fast parallel pass.
#
# Two warnings (both PER-SUITE, tunable):
#   - low speedup: parallel barely beats serial (< 2.0x pure / < 1.5x stdb).
#   - high recovery rate: too many parallel failures only pass serially, so parallelism is just
#     causing flakes -> lower -MaxParallel (> 0.6 pure / > 0.85 stdb).
#
# Pure (reads JSON, writes JSON/MD — no engine), so it is verified by
# tools/tests/test_aggregate_test_timings.ps1 against canned records.
#
# Pass -StatsLog explicitly, or -ArtifactsRoot to derive <root>/stats/test_timings.jsonl. The
# consumer-facing wrappers (run_stdb_scenarios.ps1 / validate_all.ps1) pass these from the
# project's validation.config.psd1; this script itself stays project-agnostic.
#
#   ./tools/aggregate_test_timings.ps1 -ArtifactsRoot <project>/src/artifacts
#   ./tools/aggregate_test_timings.ps1 -StatsLog <path> -OutDir <dir>
param(
    [string]$StatsLog = "",
    [string]$ArtifactsRoot = "",
    [string]$OutDir = "",
    # Default speedup/recovery thresholds. Pure suites are CPU-bound and should scale, so a 2.0x bar
    # flags a weak parallel win; STDB suites share one server (a ~2x ceiling), so 1.5x is the real
    # "server thrashing" line. Recovery is PER-SUITE: a CPU-bound pure suite recovering often means a
    # bad host (0.6), whereas an STDB suite shares one server so some contention is expected — only
    # flag near-total churn (0.85). Override per project from validation.config.psd1 Timings.*.
    [double]$PureMinSpeedup = 2.0,
    [double]$StdbMinSpeedup = 1.5,
    [double]$PureMaxRecoveryRate = 0.6,
    [double]$StdbMaxRecoveryRate = 0.85
)

$ErrorActionPreference = "Stop"
if (-not $StatsLog) {
    if ($ArtifactsRoot) { $StatsLog = Join-Path $ArtifactsRoot "stats/test_timings.jsonl" }
    else { throw "Pass -StatsLog <path> or -ArtifactsRoot <dir> (to derive <dir>/stats/test_timings.jsonl)." }
}
if (-not (Test-Path $StatsLog)) { throw "Stats log not found: $StatsLog (run a suite first)" }
if (-not $OutDir) { $OutDir = Split-Path $StatsLog -Parent }
if (-not (Test-Path $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir -Force }

# Inclusive linear-interpolation percentile (matches Excel PERCENTILE.INC).
function Get-Percentile {
    param([double[]]$Values, [double]$P)
    $n = $Values.Count
    if ($n -eq 0) { return $null }
    if ($n -eq 1) { return [math]::Round($Values[0], 2) }
    $sorted = $Values | Sort-Object
    $rank = $P * ($n - 1)
    $lo = [math]::Floor($rank)
    $hi = [math]::Ceiling($rank)
    $frac = $rank - $lo
    $val = $sorted[[int]$lo] + $frac * ($sorted[[int]$hi] - $sorted[[int]$lo])
    return [math]::Round($val, 2)
}

function Get-Mean {
    param([double[]]$Values)
    if ($Values.Count -eq 0) { return $null }
    return [math]::Round((($Values | Measure-Object -Sum).Sum / $Values.Count), 4)
}

function Get-Count {
    param($Value)
    if ($null -eq $Value) { return 0 }
    return @($Value).Count
}

# --- Load records ------------------------------------------------------------------
$records = @(
    Get-Content -Path $StatsLog |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object {
            $r = $_ | ConvertFrom-Json
            [pscustomobject]@{
                host             = [string]$r.host
                suite            = [string]$r.suite
                max_parallel     = [int]$r.max_parallel
                total_sec        = [double]$r.total_sec
                parallel_sec     = [double]$r.parallel_phase_sec
                rerun_sec        = [double]$r.rerun_phase_sec
                failed_parallel  = (Get-Count $r.failed_parallel)
                recovered        = (Get-Count $r.recovered_on_rerun)
                failed_both      = (Get-Count $r.failed_both)
            }
        }
)
if ($records.Count -eq 0) { throw "No records parsed from $StatsLog." }

$minSpeedupFor = @{ "pure" = $PureMinSpeedup; "stdb" = $StdbMinSpeedup }
$maxRecoveryFor = @{ "pure" = $PureMaxRecoveryRate; "stdb" = $StdbMaxRecoveryRate }

# --- Per-bucket aggregation (host x suite x max_parallel) --------------------------
$rows = @()
$bucketGroups = $records | Group-Object host, suite, max_parallel
foreach ($g in $bucketGroups) {
    $items = @($g.Group)
    $totals = @($items | ForEach-Object { $_.total_sec })
    $taxes = @($items | Where-Object { $_.total_sec -gt 0 } | ForEach-Object { $_.rerun_sec / $_.total_sec })
    $failedSum = (@($items | ForEach-Object { $_.failed_parallel }) | Measure-Object -Sum).Sum
    $recoveredSum = (@($items | ForEach-Object { $_.recovered }) | Measure-Object -Sum).Sum
    $failedBothSum = (@($items | ForEach-Object { $_.failed_both }) | Measure-Object -Sum).Sum
    $rows += [pscustomobject][ordered]@{
        host              = [string]$items[0].host
        suite             = [string]$items[0].suite
        max_parallel      = [int]$items[0].max_parallel
        is_serial         = ([int]$items[0].max_parallel -le 1)
        runs              = $items.Count
        total_p50         = (Get-Percentile -Values $totals -P 0.50)
        total_p10         = (Get-Percentile -Values $totals -P 0.10)
        total_p90         = (Get-Percentile -Values $totals -P 0.90)
        parallel_p50      = (Get-Percentile -Values @($items | ForEach-Object { $_.parallel_sec }) -P 0.50)
        rerun_p50         = (Get-Percentile -Values @($items | ForEach-Object { $_.rerun_sec }) -P 0.50)
        rerun_tax_mean    = (Get-Mean -Values $taxes)
        failed_parallel   = [int]$failedSum
        recovered         = [int]$recoveredSum
        failed_both       = [int]$failedBothSum
        recovery_rate     = if ($failedSum -gt 0) { [math]::Round($recoveredSum / $failedSum, 4) } else { $null }
    }
}
$rows = @($rows | Sort-Object host, suite, max_parallel)

# --- Speedup (within host x suite: serial baseline vs each parallel bucket) ---------
# Serial baseline = median total of the max_parallel<=1 bucket for that host+suite.
$speedups = @()
$warnings = @()
foreach ($hs in ($rows | Group-Object host, suite)) {
    $suiteRows = @($hs.Group)
    $serialRow = $suiteRows | Where-Object { $_.is_serial } | Select-Object -First 1
    $serialP50 = if ($serialRow) { [double]$serialRow.total_p50 } else { $null }
    foreach ($pr in ($suiteRows | Where-Object { -not $_.is_serial })) {
        $minSpeedup = if ($minSpeedupFor.ContainsKey($pr.suite)) { [double]$minSpeedupFor[$pr.suite] } else { 1.0 }
        $speedup = if ($null -ne $serialP50 -and [double]$pr.total_p50 -gt 0) { [math]::Round($serialP50 / [double]$pr.total_p50, 2) } else { $null }
        $lowSpeedup = ($null -ne $speedup -and $speedup -lt $minSpeedup)
        $speedups += [pscustomobject][ordered]@{
            host             = [string]$pr.host
            suite            = [string]$pr.suite
            max_parallel     = [int]$pr.max_parallel
            parallel_total_p50 = [double]$pr.total_p50
            serial_total_p50 = $serialP50
            speedup          = $speedup
            min_speedup      = $minSpeedup
            low_speedup      = $lowSpeedup
        }
        if ($lowSpeedup) {
            $warnings += [pscustomobject][ordered]@{
                type = "low_speedup"; host = $pr.host; suite = $pr.suite; max_parallel = $pr.max_parallel
                detail = ("{0} {1}-wide speedup {2}x < {3}x — parallel barely beats serial" -f $pr.suite, $pr.max_parallel, $speedup, $minSpeedup)
            }
        }
        $maxRecovery = if ($maxRecoveryFor.ContainsKey($pr.suite)) { [double]$maxRecoveryFor[$pr.suite] } else { 0.6 }
        if ($null -ne $pr.recovery_rate -and [double]$pr.recovery_rate -gt $maxRecovery) {
            $warnings += [pscustomobject][ordered]@{
                type = "high_recovery"; host = $pr.host; suite = $pr.suite; max_parallel = $pr.max_parallel
                detail = ("{0} {1}-wide recovery rate {2} > {3} — parallelism too aggressive; lower -MaxParallel" -f $pr.suite, $pr.max_parallel, $pr.recovery_rate, $maxRecovery)
            }
        }
    }
}

$report = [ordered]@{
    generated_from = (Resolve-Path $StatsLog).Path
    record_count   = $records.Count
    thresholds     = [ordered]@{ pure_min_speedup = $PureMinSpeedup; stdb_min_speedup = $StdbMinSpeedup; pure_max_recovery_rate = $PureMaxRecoveryRate; stdb_max_recovery_rate = $StdbMaxRecoveryRate }
    buckets        = $rows
    speedups       = $speedups
    warnings       = $warnings
}

$jsonPath = Join-Path $OutDir "test-timing-report.json"
$report | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding utf8

# --- Markdown ----------------------------------------------------------------------
$md = [System.Text.StringBuilder]::new()
$null = $md.AppendLine("# Validation Timing Report")
$null = $md.AppendLine("")
$null = $md.AppendLine("Source: ``$($report.generated_from)``  ·  records: **$($report.record_count)**")
$null = $md.AppendLine("")
$null = $md.AppendLine("| Host | Suite | Parallel | Runs | Total p50 (s) | Parallel p50 | Rerun p50 | Rerun tax | Recovery | Genuine (failed_both) |")
$null = $md.AppendLine("|---|---|---|---|---|---|---|---|---|---|")
foreach ($r in $rows) {
    $rec = if ($null -ne $r.recovery_rate) { $r.recovery_rate } else { "-" }
    $null = $md.AppendLine("| $($r.host) | $($r.suite) | $($r.max_parallel) | $($r.runs) | $($r.total_p50) | $($r.parallel_p50) | $($r.rerun_p50) | $($r.rerun_tax_mean) | $rec | $($r.failed_both) |")
}
$null = $md.AppendLine("")
$null = $md.AppendLine("## Is parallel worth it? (speedup = serial total / parallel total, within a host)")
if ($speedups.Count -eq 0) {
    $null = $md.AppendLine("_No host+suite has both a serial (max_parallel 1) and a parallel record yet — run each suite once at -MaxParallel 1 to establish the baseline._")
}
else {
    $null = $md.AppendLine("| Host | Suite | Parallel | Parallel total p50 | Serial total p50 | Speedup | Threshold |")
    $null = $md.AppendLine("|---|---|---|---|---|---|---|")
    foreach ($s in $speedups) {
        $sp = if ($null -ne $s.speedup) { "$($s.speedup)x" } else { "n/a (no serial baseline)" }
        $flag = if ($s.low_speedup) { " ⚠️" } else { "" }
        $null = $md.AppendLine("| $($s.host) | $($s.suite) | $($s.max_parallel) | $($s.parallel_total_p50) | $($s.serial_total_p50) | $sp$flag | $($s.min_speedup)x |")
    }
}
$null = $md.AppendLine("")
if ($warnings.Count -gt 0) {
    $null = $md.AppendLine("## ⚠️ Warnings")
    foreach ($w in $warnings) { $null = $md.AppendLine("- **$($w.type)**: $($w.detail)") }
}
else {
    $null = $md.AppendLine("_No warnings._")
}
$mdPath = Join-Path $OutDir "test-timing-report.md"
$md.ToString() | Set-Content -Path $mdPath -Encoding utf8

# --- Console summary ---------------------------------------------------------------
Write-Host "=== Validation timing report ===" -ForegroundColor Cyan
Write-Host ("  records={0}  buckets={1}  speedup-rows={2}" -f $records.Count, $rows.Count, $speedups.Count)
foreach ($s in $speedups) {
    $sp = if ($null -ne $s.speedup) { "{0}x" -f $s.speedup } else { "n/a (no serial baseline)" }
    $color = if ($s.low_speedup) { "Yellow" } else { "Green" }
    Write-Host ("  {0} {1} {2}-wide: {3} (parallel {4}s vs serial {5}s)" -f $s.host, $s.suite, $s.max_parallel, $sp, $s.parallel_total_p50, $s.serial_total_p50) -ForegroundColor $color
}
foreach ($w in $warnings) { Write-Host ("  WARNING [{0}] {1}" -f $w.type, $w.detail) -ForegroundColor Yellow }
Write-Host "  -> $jsonPath"
Write-Host "  -> $mdPath"
exit 0
