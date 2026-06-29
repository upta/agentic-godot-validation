# Pure verdict logic for the STDB suite's parallel pass + (single) serial re-run.
# Dot-sourced by run_stdb_scenarios.ps1 and exercised engine-free by
# tools/tests/test_stdb_suite_verdict.ps1.
#
# Policy = ANNOTATE (strict): the serial re-run is DIAGNOSTIC ONLY. A scenario that fails the
# parallel pass keeps the suite RED even if it passes the serial re-run — for a server-backed
# (SpacetimeDB) suite, a parallel-only failure IS the load-sensitive regression the suite exists
# to catch, so we annotate it ("recovered on rerun") but never forgive it. Forgiving here would
# re-open the masking hole: a real contention regression would pass on its lone uncontended retry
# and the suite would go green. The headline guard for this lives in the unit test
# (recovered => exit 1). Pure CPU-only suites opt into forgiveness elsewhere (run_all_scenarios.ps1
# -RerunVerdict forgive); the STDB suite deliberately does not.
function Get-StdbSuiteVerdict {
    param(
        # Each element needs .Scenario (string), .Validated (bool), .Flaky (bool).
        [object[]]$ParallelResults = @(),
        # Each element needs .Scenario (string), .Validated (bool). One entry per re-run scenario.
        [object[]]$RerunResults = @()
    )

    $failedParallel = @($ParallelResults | Where-Object { -not $_.Validated } | ForEach-Object { [string]$_.Scenario } | Sort-Object)
    $flaky = @($ParallelResults | Where-Object { [bool]$_.Flaky } | ForEach-Object { [string]$_.Scenario } | Sort-Object)

    # Index re-run outcomes by scenario name so a failed scenario can be classified.
    $rerunValidated = @{}
    foreach ($r in $RerunResults) {
        if ($null -ne $r) { $rerunValidated[[string]$r.Scenario] = [bool]$r.Validated }
    }

    $recovered = @()
    $failedBoth = @()
    foreach ($name in $failedParallel) {
        # Classify ONLY scenarios that were actually re-run: recovered (the single serial
        # attempt validated) vs failed_both (it failed again). A parallel failure that was
        # NEVER re-run (-NoRerun, or no concurrency to blame) stays in failed_parallel only —
        # calling it "failed_both" would lie about the contention-vs-real signal this exists
        # to capture. Either way the suite stays RED (strict; see suite_exit_code below).
        if ($rerunValidated.ContainsKey($name)) {
            if ($rerunValidated[$name]) { $recovered += $name }
            else { $failedBoth += $name }
        }
    }

    # STRICT: any parallel failure fails the suite, regardless of the re-run result.
    $suiteExitCode = if ($failedParallel.Count -gt 0) { 1 } else { 0 }
    $suiteStatus = if ($failedParallel.Count -gt 0) { "failed" } elseif ($flaky.Count -gt 0) { "flaky" } else { "pass" }

    return [ordered]@{
        failed_parallel    = @($failedParallel)
        recovered_on_rerun = @($recovered | Sort-Object)
        failed_both        = @($failedBoth | Sort-Object)
        flaky_scenarios    = @($flaky)
        suite_exit_code    = $suiteExitCode
        suite_status       = $suiteStatus
    }
}
