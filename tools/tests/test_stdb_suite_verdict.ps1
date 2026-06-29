# Pure (engine-free) unit check for Get-StdbSuiteVerdict (tools/stdb_suite_verdict.ps1):
# feeds canned parallel + re-run results and asserts the classification (recovered vs
# failed_both vs flaky) and the STRICT suite verdict.
#
# The headline assertion is Test 2: a scenario that FAILS in parallel and PASSES the serial
# re-run is annotated "recovered_on_rerun" but the suite STILL exits non-zero. That is the
# regression guard for the no-forgive policy — if this ever flips to exit 0, the masking hole
# (a real contention regression passing on its lone uncontended retry) has been re-opened.
#
#   ./tools/tests/test_stdb_suite_verdict.ps1
param()

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path $PSScriptRoot -Parent) "stdb_suite_verdict.ps1")

$script:failures = 0
function Assert-Eq {
    param([string]$Name, $Actual, $Expected)
    if ([string]$Actual -eq [string]$Expected) { Write-Host ("  ok  {0} = {1}" -f $Name, $Actual) }
    else { Write-Host ("  FAIL {0}: expected '{1}', got '{2}'" -f $Name, $Expected, $Actual) -ForegroundColor Red; $script:failures++ }
}
function Assert-Set {
    param([string]$Name, $Actual, [string[]]$Expected)
    $a = @($Actual | Sort-Object) -join ","
    $e = @($Expected | Sort-Object) -join ","
    if ($a -eq $e) { Write-Host ("  ok  {0} = [{1}]" -f $Name, $a) }
    else { Write-Host ("  FAIL {0}: expected [{1}], got [{2}]" -f $Name, $e, $a) -ForegroundColor Red; $script:failures++ }
}

function Res {
    param([string]$Scenario, [bool]$Validated, [bool]$Flaky = $false)
    [pscustomobject]@{ Scenario = $Scenario; Validated = $Validated; Flaky = $Flaky }
}

# =================================================================================
# Test 1 — all clean: no failures, no re-run -> pass, exit 0
# =================================================================================
Write-Host "Test 1 - all clean:"
$v = Get-StdbSuiteVerdict -ParallelResults @((Res "a" $true), (Res "b" $true), (Res "c" $true)) -RerunResults @()
Assert-Set "failed_parallel" $v.failed_parallel @()
Assert-Set "recovered_on_rerun" $v.recovered_on_rerun @()
Assert-Set "failed_both" $v.failed_both @()
Assert-Eq "suite_exit_code" $v.suite_exit_code 0
Assert-Eq "suite_status" $v.suite_status "pass"

# =================================================================================
# Test 2 — RECOVERED: fails parallel, passes serial re-run. STRICT: suite STILL RED.
#          *** anti-masking regression guard ***
# =================================================================================
Write-Host "Test 2 - recovered on rerun (must STILL be red):"
$v = Get-StdbSuiteVerdict -ParallelResults @((Res "a" $false), (Res "b" $true)) -RerunResults @((Res "a" $true))
Assert-Set "failed_parallel" $v.failed_parallel @("a")
Assert-Set "recovered_on_rerun" $v.recovered_on_rerun @("a")
Assert-Set "failed_both" $v.failed_both @()
Assert-Eq "suite_exit_code (STAYS 1)" $v.suite_exit_code 1
Assert-Eq "suite_status (STAYS failed)" $v.suite_status "failed"

# =================================================================================
# Test 3 — failed both: fails parallel and fails the serial re-run
# =================================================================================
Write-Host "Test 3 - failed both:"
$v = Get-StdbSuiteVerdict -ParallelResults @((Res "a" $false), (Res "b" $true)) -RerunResults @((Res "a" $false))
Assert-Set "failed_both" $v.failed_both @("a")
Assert-Set "recovered_on_rerun" $v.recovered_on_rerun @()
Assert-Eq "suite_exit_code" $v.suite_exit_code 1
Assert-Eq "suite_status" $v.suite_status "failed"

# =================================================================================
# Test 4 — flaky only: validated-but-flaky, no real failures -> flaky/green
# =================================================================================
Write-Host "Test 4 - flaky only:"
$v = Get-StdbSuiteVerdict -ParallelResults @((Res "a" $true), (Res "b" $true $true)) -RerunResults @()
Assert-Set "failed_parallel" $v.failed_parallel @()
Assert-Set "flaky_scenarios" $v.flaky_scenarios @("b")
Assert-Eq "suite_exit_code" $v.suite_exit_code 0
Assert-Eq "suite_status" $v.suite_status "flaky"

# =================================================================================
# Test 5 — mixed: a recovered, c failed_both, b flaky, d clean -> red, fully classified
# =================================================================================
Write-Host "Test 5 - mixed:"
$v = Get-StdbSuiteVerdict `
    -ParallelResults @((Res "a" $false), (Res "b" $true $true), (Res "c" $false), (Res "d" $true)) `
    -RerunResults @((Res "a" $true), (Res "c" $false))
Assert-Set "failed_parallel" $v.failed_parallel @("a", "c")
Assert-Set "recovered_on_rerun" $v.recovered_on_rerun @("a")
Assert-Set "failed_both" $v.failed_both @("c")
Assert-Set "flaky_scenarios" $v.flaky_scenarios @("b")
Assert-Eq "suite_exit_code" $v.suite_exit_code 1
Assert-Eq "suite_status" $v.suite_status "failed"

# =================================================================================
# Test 6 — failed parallel but NOT re-run (e.g. -NoRerun): stays failed_parallel only,
#          NOT mislabeled failed_both, and still RED (never forgiven).
# =================================================================================
Write-Host "Test 6 - failed parallel, no rerun supplied:"
$v = Get-StdbSuiteVerdict -ParallelResults @((Res "a" $false), (Res "b" $true)) -RerunResults @()
Assert-Set "failed_parallel" $v.failed_parallel @("a")
Assert-Set "failed_both (none re-run)" $v.failed_both @()
Assert-Set "recovered_on_rerun" $v.recovered_on_rerun @()
Assert-Eq "suite_exit_code (STAYS 1)" $v.suite_exit_code 1

Write-Host ""
if ($script:failures -gt 0) {
    Write-Host ("STDB VERDICT UNIT CHECK FAILED -> {0} assertion(s)" -f $script:failures) -ForegroundColor Red
    exit 1
}
Write-Host "STDB VERDICT UNIT CHECK OK (classification + STRICT no-forgive verdict)" -ForegroundColor Green
exit 0
