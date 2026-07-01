# Pure (engine-free) unit check for aggregate_test_timings.ps1: writes a canned
# test_timings.jsonl with known per-suite-run records, runs the aggregator, and asserts the
# bucketing, percentiles, within-host speedup (serial vs parallel), recovery rate, the two
# warnings (low speedup / high recovery), and the no-serial-baseline edge. This verifies the
# "is parallel worth it?" math without the slow Godot suite.
#
#   ./tools/tests/test_aggregate_test_timings.ps1
param()

$ErrorActionPreference = "Stop"
$aggregator = Join-Path (Split-Path $PSScriptRoot -Parent) "aggregate_test_timings.ps1"

$script:failures = 0
function Assert-Near {
    param([string]$Name, $Actual, [double]$Expected, [double]$Tol = 0.02)
    if ($null -eq $Actual) { Write-Host ("  FAIL {0}: expected {1}, got <null>" -f $Name, $Expected) -ForegroundColor Red; $script:failures++; return }
    $a = [double]$Actual
    if ([math]::Abs($a - $Expected) -le $Tol) { Write-Host ("  ok  {0} = {1}" -f $Name, $a) }
    else { Write-Host ("  FAIL {0}: expected {1}, got {2}" -f $Name, $Expected, $a) -ForegroundColor Red; $script:failures++ }
}
function Assert-True {
    param([string]$Name, [bool]$Cond)
    if ($Cond) { Write-Host ("  ok  {0}" -f $Name) } else { Write-Host ("  FAIL {0}" -f $Name) -ForegroundColor Red; $script:failures++ }
}
function Assert-Null {
    param([string]$Name, $Actual)
    if ($null -eq $Actual) { Write-Host ("  ok  {0} = <null>" -f $Name) } else { Write-Host ("  FAIL {0}: expected <null>, got {1}" -f $Name, $Actual) -ForegroundColor Red; $script:failures++ }
}

function New-Rec {
    param([string]$Host_, [string]$Suite, [int]$MaxP, [double]$Total, [double]$Par, [double]$Rerun, [int]$Failed, [int]$Recovered, [int]$FailedBoth)
    $names = { param($n, $p) 1..$n | ForEach-Object { "$p$_" } }
    [ordered]@{
        timestamp          = "2026-06-26T00:00:00Z"
        suite              = $Suite
        host               = $Host_
        cores              = 8
        max_parallel       = $MaxP
        scenario_count     = 50
        parallel_phase_sec = $Par
        rerun_phase_sec    = $Rerun
        total_sec          = $Total
        sum_scenario_sec   = $Total
        failed_parallel    = @(if ($Failed -gt 0) { & $names $Failed "f" } else { @() })
        recovered_on_rerun = @(if ($Recovered -gt 0) { & $names $Recovered "f" } else { @() })
        failed_both        = @(if ($FailedBoth -gt 0) { & $names $FailedBoth "b" } else { @() })
        verdict_policy     = "forgive"
        suite_status       = "pass"
    } | ConvertTo-Json -Compress
}

$dir = Join-Path ([System.IO.Path]::GetTempPath()) ("agv-timingtest-" + [System.Guid]::NewGuid().ToString("N").Substring(0, 8))
$null = New-Item -ItemType Directory -Path $dir -Force
$log = Join-Path $dir "test_timings.jsonl"

$lines = @(
    # H1 pure: serial baseline 170; parallel 4-wide clean (no failures), totals 50/60/70 -> p50 60
    (New-Rec "H1" "pure" 1 170 170 0 0 0 0)
    (New-Rec "H1" "pure" 4 50 50 0 0 0 0)
    (New-Rec "H1" "pure" 4 60 60 0 0 0 0)
    (New-Rec "H1" "pure" 4 70 70 0 0 0 0)
    # H1 stdb: serial 200; parallel 2-wide total 180 (rerun 30), 5 failed all recovered
    (New-Rec "H1" "stdb" 1 200 200 0 0 0 0)
    (New-Rec "H1" "stdb" 2 180 150 30 5 5 0)
    # H2 stdb: parallel 2-wide only, NO serial baseline; 1 failed recovered
    (New-Rec "H2" "stdb" 2 100 90 10 1 1 0)
    # H3 pure 4-wide: EVEN n=4 (40/50/60/70) -> exercises percentile interpolation (p50 55, p10 43, p90 67)
    (New-Rec "H3" "pure" 4 40 40 0 0 0 0)
    (New-Rec "H3" "pure" 4 50 50 0 0 0 0)
    (New-Rec "H3" "pure" 4 60 60 0 0 0 0)
    (New-Rec "H3" "pure" 4 70 70 0 0 0 0)
    # H3 stdb 2-wide: 2 failed, none recovered, both genuine -> failed_both surfaced, recovery 0 (no warning)
    (New-Rec "H3" "stdb" 2 100 80 20 2 0 2)
    # H4: SAME recovery rate 0.7 (7 of 10) on pure vs stdb -> per-suite thresholds warn pure (>0.6) but NOT stdb (<0.85)
    (New-Rec "H4" "pure" 2 100 80 20 10 7 3)
    (New-Rec "H4" "stdb" 2 100 80 20 10 7 3)
)
Set-Content -Path $log -Value $lines -Encoding utf8

function Find-Row { param($rows, $h, $s, $p) $rows | Where-Object { $_.host -eq $h -and $_.suite -eq $s -and [int]$_.max_parallel -eq $p } | Select-Object -First 1 }

try {
    & $aggregator -StatsLog $log -OutDir $dir *> $null
    $code = $LASTEXITCODE
    $report = Get-Content -Raw (Join-Path $dir "test-timing-report.json") | ConvertFrom-Json

    Write-Host "Test — load + buckets:"
    Assert-Near "exit code 0" $code 0
    Assert-Near "record_count" $report.record_count 14
    $pureP = Find-Row $report.buckets "H1" "pure" 4
    Assert-Near "H1/pure/4 runs" $pureP.runs 3
    Assert-Near "H1/pure/4 total_p50" $pureP.total_p50 60
    Assert-Null "H1/pure/4 recovery_rate (no failures)" $pureP.recovery_rate
    $stdbP = Find-Row $report.buckets "H1" "stdb" 2
    Assert-Near "H1/stdb/2 recovery_rate" $stdbP.recovery_rate 1.0
    Assert-Near "H1/stdb/2 rerun_tax_mean" $stdbP.rerun_tax_mean 0.1667 0.001

    Write-Host "Test — percentile interpolation (even n) + failed_both surfaced:"
    $pureEven = Find-Row $report.buckets "H3" "pure" 4   # totals 40/50/60/70
    Assert-Near "H3/pure/4 total_p50 (interp -> 55)" $pureEven.total_p50 55
    Assert-Near "H3/pure/4 total_p10 (interp -> 43)" $pureEven.total_p10 43
    Assert-Near "H3/pure/4 total_p90 (interp -> 67)" $pureEven.total_p90 67
    $stdbGenuine = Find-Row $report.buckets "H3" "stdb" 2
    Assert-Near "H3/stdb/2 failed_both surfaced" $stdbGenuine.failed_both 2
    Assert-Near "H3/stdb/2 recovery_rate 0 (none recovered)" $stdbGenuine.recovery_rate 0

    Write-Host "Test — speedup (within host: serial / parallel):"
    $spPure = $report.speedups | Where-Object { $_.host -eq "H1" -and $_.suite -eq "pure" } | Select-Object -First 1
    Assert-Near "H1/pure speedup 170/60" $spPure.speedup 2.83 0.01
    Assert-True "H1/pure not low (2.83 >= 2.0)" (-not $spPure.low_speedup)
    $spStdb = $report.speedups | Where-Object { $_.host -eq "H1" -and $_.suite -eq "stdb" } | Select-Object -First 1
    Assert-Near "H1/stdb speedup 200/180" $spStdb.speedup 1.11 0.01
    Assert-True "H1/stdb IS low (1.11 < 1.5)" ([bool]$spStdb.low_speedup)
    $spH2 = $report.speedups | Where-Object { $_.host -eq "H2" -and $_.suite -eq "stdb" } | Select-Object -First 1
    Assert-Null "H2/stdb speedup (no serial baseline)" $spH2.speedup
    Assert-True "H2/stdb not flagged low (null speedup)" (-not $spH2.low_speedup)

    Write-Host "Test — warnings:"
    $lowW = @($report.warnings | Where-Object { $_.type -eq "low_speedup" })
    Assert-Near "low_speedup warnings count" $lowW.Count 1
    Assert-True "low_speedup is H1/stdb/2" ($lowW[0].host -eq "H1" -and $lowW[0].suite -eq "stdb")
    $recW = @($report.warnings | Where-Object { $_.type -eq "high_recovery" })
    Assert-Near "high_recovery warnings count (H1/stdb, H2/stdb, H4/pure)" $recW.Count 3
    Assert-True "H4/pure/2 warns (recovery 0.7 > 0.6 pure)" (@($recW | Where-Object { $_.host -eq "H4" -and $_.suite -eq "pure" }).Count -eq 1)
    Assert-True "H4/stdb/2 does NOT warn (recovery 0.7 < 0.85 stdb)" (@($recW | Where-Object { $_.host -eq "H4" -and $_.suite -eq "stdb" }).Count -eq 0)
}
finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }

Write-Host ""
if ($script:failures -gt 0) {
    Write-Host ("TIMING AGGREGATOR UNIT CHECK FAILED -> {0} assertion(s)" -f $script:failures) -ForegroundColor Red
    exit 1
}
Write-Host "TIMING AGGREGATOR UNIT CHECK OK (buckets + speedup + recovery + warnings + no-baseline edge)" -ForegroundColor Green
exit 0
