param(
    [string]$ScenarioDirectory = "",
    [string]$ProjectPath = $(
        $root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
        if (Test-Path (Join-Path $root "project.godot")) { $root }
        elseif (Test-Path (Join-Path $root "client" "project.godot")) { Join-Path $root "client" }
        else { $root }
    ),
    [string]$GodotExe = $env:GODOT_EXE,
    [int]$Screen = -1,
    [int]$KeepLatestPerScenario = 10,
    [int]$KeepLatestSuiteRuns = 10,
    [int]$RepeatCount = 1,
    [int]$MaxParallel = 4,
    [switch]$Record,
    [int]$RecordFps = 30,
    # After the parallel pass, re-run each failed scenario ONCE, serially, on its own process.
    # A parallel-only failure is usually environmental (CPU/focus contention), so the single
    # uncontended attempt is the diagnostic. -RerunVerdict annotate (default, safe for a generic
    # kit): report the scenario as recovered/failed_both but KEEP the failure (suite stays red).
    # forgive: a scenario that passes the re-run is treated as passed for the suite verdict — opt
    # in per project (Nomad's pure suite passes -RerunVerdict forgive via validate_all). Skipped
    # for serial runs (MaxParallel 1) and disabled by -NoRerun.
    [switch]$NoRerun,
    [ValidateSet("forgive", "annotate")][string]$RerunVerdict = "annotate"
)

$ErrorActionPreference = "Stop"

function Resolve-ScenarioDirectory {
    param(
        [string]$RequestedScenarioDirectory,
        [string]$ResolvedProjectPath
    )

    if ([string]::IsNullOrWhiteSpace($RequestedScenarioDirectory)) {
        $defaultCandidates = @(
            "validation/scenarios",
            "examples/minimal_poc/validation/scenarios"
        )

        foreach ($candidate in $defaultCandidates) {
            $candidatePath = Join-Path $ResolvedProjectPath $candidate
            if ((Test-Path $candidatePath) -and (Get-ChildItem -Path $candidatePath -Filter *.json -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                return (Resolve-Path $candidatePath).Path
            }
        }

        throw "Could not locate a scenario directory under validation/scenarios or examples/minimal_poc/validation/scenarios."
    }

    if ([System.IO.Path]::IsPathRooted($RequestedScenarioDirectory)) {
        return (Resolve-Path $RequestedScenarioDirectory).Path
    }

    return (Resolve-Path (Join-Path $ResolvedProjectPath $RequestedScenarioDirectory)).Path
}

function Convert-ToProjectRelativePath {
    param(
        [string]$Path,
        [string]$ResolvedProjectPath
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $absolutePath = [System.IO.Path]::GetFullPath($Path)
    $projectRootWithSeparator = $ResolvedProjectPath.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($absolutePath.StartsWith($projectRootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $absolutePath.Substring($projectRootWithSeparator.Length).Replace('\', '/')
    }

    return $absolutePath.Replace('\', '/')
}

function Get-SuiteStatus {
    param(
        [bool]$HasFailures,
        [bool]$HasFlakyScenarios
    )

    if ($HasFlakyScenarios) {
        return "flaky"
    }

    if ($HasFailures) {
        return "failed"
    }

    return "pass"
}

# Resolve a scenario's id from its CONTRACT (the canonical key the rest of suite.json uses) rather
# than the filename — the kit must not assume filename == scenario_id. Falls back to the file stem
# if the contract can't be read. Used to key the re-run classification lists to scenario_id.
function Get-ScenarioId {
    param([System.IO.FileInfo]$ScenarioFile)
    try {
        $contract = Get-Content -Path $ScenarioFile.FullName -Raw | ConvertFrom-Json
        if ($contract -and $contract.scenario_id) { return [string]$contract.scenario_id }
    }
    catch { }
    return $ScenarioFile.BaseName
}

# Runs a batch of scenarios concurrently (ThrottleLimit = MaxParallel) and returns,
# for each scenario file, the captured run_scenario.ps1 output lines and its exit code.
# Parallel safety: each scenario is its own Godot process writing a unique timestamped
# artifact dir; -SkipArtifactPrune avoids concurrent prune races (a single prune runs at
# the end of the suite). Test windows open with WINDOW_FLAG_NO_FOCUS so concurrent
# instances never steal each other's input focus.
function Invoke-ScenarioBatch {
    param(
        [System.IO.FileInfo[]]$ScenarioFiles,
        [int]$MaxParallel,
        [string]$RunScenarioScriptPath,
        [string]$ResolvedProjectPath,
        [string]$GodotExe,
        [int]$Screen,
        [int]$KeepLatestPerScenario,
        [switch]$Record,
        [int]$RecordFps
    )

    $effectiveThrottle = [Math]::Max(1, $MaxParallel)

    if ($effectiveThrottle -eq 1) {
        $serialOutputs = @()
        foreach ($scenarioFile in $ScenarioFiles) {
            Write-Output ("RUNNING {0}" -f $scenarioFile.Name)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $runOutput = & $RunScenarioScriptPath `
                -Scenario $scenarioFile.FullName `
                -ProjectPath $ResolvedProjectPath `
                -GodotExe $GodotExe `
                -Screen $Screen `
                -KeepLatestPerScenario $KeepLatestPerScenario `
                -Record:$Record `
                -RecordFps $RecordFps `
                -SkipArtifactPrune
            $exit = $LASTEXITCODE
            $sw.Stop()
            $serialOutputs += [pscustomobject]@{
                FullName = $scenarioFile.FullName
                Output   = @($runOutput)
                Exit     = $exit
                Duration = [math]::Round($sw.Elapsed.TotalSeconds, 2)
            }
        }
        return $serialOutputs
    }

    return $ScenarioFiles | ForEach-Object -ThrottleLimit $effectiveThrottle -Parallel {
        $scenarioFile = $_
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $runOutput = & $using:RunScenarioScriptPath `
            -Scenario $scenarioFile.FullName `
            -ProjectPath $using:ResolvedProjectPath `
            -GodotExe $using:GodotExe `
            -Screen $using:Screen `
            -KeepLatestPerScenario $using:KeepLatestPerScenario `
            -Record:$using:Record `
            -RecordFps $using:RecordFps `
            -SkipArtifactPrune 2>&1
        $exit = $LASTEXITCODE
        $sw.Stop()
        [pscustomobject]@{
            FullName = $scenarioFile.FullName
            Output   = @($runOutput)
            Exit     = $exit
            Duration = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        }
    }
}

if ($RepeatCount -lt 1) {
    throw "RepeatCount must be 1 or greater."
}

if ($KeepLatestSuiteRuns -lt 0) {
    throw "KeepLatestSuiteRuns must be 0 or greater."
}

if ($MaxParallel -lt 1) {
    throw "MaxParallel must be 1 or greater."
}

$resolvedProjectPath = (Resolve-Path $ProjectPath).Path
$resolvedScenarioDirectory = Resolve-ScenarioDirectory -RequestedScenarioDirectory $ScenarioDirectory -ResolvedProjectPath $resolvedProjectPath
$scenarioFiles = Get-ChildItem -Path $resolvedScenarioDirectory -Filter *.json -File | Sort-Object Name

if ($scenarioFiles.Count -eq 0) {
    throw "No scenario contracts were found under $resolvedScenarioDirectory."
}

$artifactsRoot = Join-Path $resolvedProjectPath "artifacts"
$suiteRunId = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$suiteRunPath = Join-Path $artifactsRoot (Join-Path "suites" $suiteRunId)
$null = New-Item -ItemType Directory -Path $suiteRunPath -Force

$runScenarioScriptPath = Join-Path $PSScriptRoot "run_scenario.ps1"
$pruneScriptPath = Join-Path $PSScriptRoot "prune_artifacts.ps1"
$suiteStartedUtc = (Get-Date).ToUniversalTime()
$allResults = @()
$iterations = @()
$scenarioAggregateMap = @{}
# Re-run + efficiency-stats accumulators (see the serial re-run block + the stats record below).
$doRerun = (-not $NoRerun) -and ($MaxParallel -gt 1)
$parallelMsecTotal = 0
$rerunMsecTotal = 0
$sumScenarioSecTotal = 0.0
$recoveredIds = @()
$failedBothIds = @()
$failedParallelIds = @()

for ($iteration = 1; $iteration -le $RepeatCount; $iteration++) {
    Write-Output (("ITERATION {0}/{1} (max parallel {2})" -f $iteration, $RepeatCount, $MaxParallel))
    $iterationResults = @()

    # Run phase: execute every scenario (concurrently when MaxParallel > 1), then
    # index the captured output by scenario path so the aggregation below stays serial
    # and deterministic regardless of completion order.
    $parallelSw = [System.Diagnostics.Stopwatch]::StartNew()
    $batchOutputs = Invoke-ScenarioBatch `
        -ScenarioFiles $scenarioFiles `
        -MaxParallel $MaxParallel `
        -RunScenarioScriptPath $runScenarioScriptPath `
        -ResolvedProjectPath $resolvedProjectPath `
        -GodotExe $GodotExe `
        -Screen $Screen `
        -KeepLatestPerScenario $KeepLatestPerScenario `
        -Record:$Record `
        -RecordFps $RecordFps
    $parallelSw.Stop()
    $parallelMsecTotal += $parallelSw.ElapsedMilliseconds
    # Σ of per-scenario PARALLEL-pass durations = the contended upper-bound serial estimate.
    $sumScenarioSecTotal += (@($batchOutputs | ForEach-Object { [double]$_.Duration }) | Measure-Object -Sum).Sum

    $outputsByFile = @{}
    foreach ($batchOutput in $batchOutputs) {
        $outputsByFile[[string]$batchOutput.FullName] = $batchOutput
    }

    # Serial re-run of this iteration's parallel failures (single attempt each). A parallel-only
    # failure that passes serially is "recovered" (environmental); one that fails again is
    # "failed_both" (genuine). Under -RerunVerdict forgive the recovered scenario's result is
    # replaced with its passing re-run so the aggregation below treats it as a pass; under
    # annotate the original failure stands (suite stays red). Either way the classification +
    # phase timing feed the efficiency stats. Serial runs / -NoRerun skip this entirely.
    if ($doRerun) {
        $failedFiles = @($scenarioFiles | Where-Object {
                $b = $outputsByFile[[string]$_.FullName]
                ($null -eq $b) -or ([int]$b.Exit -ne 0)
            })
        if ($failedFiles.Count -gt 0) {
            $failedParallelIds += @($failedFiles | ForEach-Object { Get-ScenarioId -ScenarioFile $_ })
            Write-Output ("RERUN {0} failed scenario(s) serially (verdict={1}): {2}" -f `
                    $failedFiles.Count, $RerunVerdict, (($failedFiles | ForEach-Object { $_.Name }) -join ", "))
            $rerunSw = [System.Diagnostics.Stopwatch]::StartNew()
            $rerunOutputs = Invoke-ScenarioBatch `
                -ScenarioFiles $failedFiles `
                -MaxParallel 1 `
                -RunScenarioScriptPath $runScenarioScriptPath `
                -ResolvedProjectPath $resolvedProjectPath `
                -GodotExe $GodotExe `
                -Screen $Screen `
                -KeepLatestPerScenario $KeepLatestPerScenario `
                -Record:$Record `
                -RecordFps $RecordFps
            $rerunSw.Stop()
            $rerunMsecTotal += $rerunSw.ElapsedMilliseconds

            $rerunByFile = @{}
            foreach ($ro in $rerunOutputs) { $rerunByFile[[string]$ro.FullName] = $ro }
            foreach ($failedFile in $failedFiles) {
                $ro = $rerunByFile[[string]$failedFile.FullName]
                $rerunPassed = ($null -ne $ro) -and ([int]$ro.Exit -eq 0)
                $rerunId = Get-ScenarioId -ScenarioFile $failedFile
                if ($rerunPassed) {
                    $recoveredIds += $rerunId
                    # forgive: the passing serial re-run stands in for the failed parallel result.
                    if ($RerunVerdict -eq "forgive") { $outputsByFile[[string]$failedFile.FullName] = $ro }
                }
                else {
                    $failedBothIds += $rerunId
                }
            }
        }
    }

    foreach ($scenarioFile in $scenarioFiles) {
        $batchOutput = $outputsByFile[[string]$scenarioFile.FullName]
        $runOutput = if ($null -ne $batchOutput) { @($batchOutput.Output) } else { @() }
        $runExitCode = if ($null -ne $batchOutput) { [int]$batchOutput.Exit } else { 1 }

        $resultLine = $runOutput | Where-Object { $_ -like "RESULT *" } | Select-Object -Last 1
        $artifactsLine = $runOutput | Where-Object { $_ -like "ARTIFACTS *" } | Select-Object -Last 1

        Write-Output (("RAN {0} (iteration {1}/{2}) exit={3}" -f $scenarioFile.Name, $iteration, $RepeatCount, $runExitCode))

        if ($null -eq $resultLine) {
            $result = [ordered]@{
                scenario_id = $scenarioFile.BaseName
                scenario_file = Convert-ToProjectRelativePath -Path $scenarioFile.FullName -ResolvedProjectPath $resolvedProjectPath
                iteration = $iteration
                status = "failed"
                engine_exit_code = $runExitCode
                final_exit_code = $runExitCode
                artifact_path = if ($artifactsLine) { $artifactsLine.Substring(10) } else { $null }
                missing_artifacts = @()
                parse_error = "run_scenario.ps1 did not emit a RESULT line."
            }
        }
        else {
            $result = $resultLine.Substring(7) | ConvertFrom-Json -AsHashtable
            if ($artifactsLine -and (-not $result.ContainsKey("artifact_path") -or [string]::IsNullOrWhiteSpace([string]$result.artifact_path))) {
                $result.artifact_path = $artifactsLine.Substring(10)
            }
            if (-not $result.ContainsKey("final_exit_code")) {
                $result.final_exit_code = $runExitCode
            }
            $result.scenario_file = Convert-ToProjectRelativePath -Path $scenarioFile.FullName -ResolvedProjectPath $resolvedProjectPath
            $result.iteration = $iteration
        }

        $resultObject = [pscustomobject]$result
        $iterationResults += $resultObject
        $allResults += $resultObject

        $scenarioId = [string]$resultObject.scenario_id
        if (-not $scenarioAggregateMap.ContainsKey($scenarioId)) {
            $scenarioAggregateMap[$scenarioId] = [ordered]@{
                scenario_id = $scenarioId
                scenario_file = [string]$resultObject.scenario_file
                run_count = 0
                pass_count = 0
                fail_count = 0
                final_exit_codes = @()
                statuses = @()
                latest_result = $null
            }
        }

        $aggregate = $scenarioAggregateMap[$scenarioId]
        $aggregate.run_count += 1
        if ([int]$resultObject.final_exit_code -eq 0) {
            $aggregate.pass_count += 1
        }
        else {
            $aggregate.fail_count += 1
        }
        $aggregate.final_exit_codes += [int]$resultObject.final_exit_code
        $aggregate.statuses += [string]$resultObject.status
        $aggregate.latest_result = $resultObject
        $scenarioAggregateMap[$scenarioId] = $aggregate
    }

    # Any non-zero scenario exit fails the iteration. Use a 0/1 flag, NOT a numeric max:
    # engine crashes report negative codes (e.g. -1073741819 / 0xC0000005) that a `-gt`
    # comparison would treat as "less than a pass" and silently swallow.
    $iterationFinalExitCode = 0
    foreach ($iterationResult in $iterationResults) {
        if ([int]$iterationResult.final_exit_code -ne 0) {
            $iterationFinalExitCode = 1
        }
    }

    $iterations += [pscustomobject][ordered]@{
        iteration = $iteration
        scenario_count = $iterationResults.Count
        passed_count = @($iterationResults | Where-Object { [int]$_.final_exit_code -eq 0 }).Count
        failed_count = @($iterationResults | Where-Object { [int]$_.final_exit_code -ne 0 }).Count
        final_exit_code = $iterationFinalExitCode
        scenarios = $iterationResults
    }
}

$scenarioAggregate = @()
foreach ($scenarioId in ($scenarioAggregateMap.Keys | Sort-Object)) {
    $aggregate = $scenarioAggregateMap[$scenarioId]
    $aggregate.flaky = ($aggregate.pass_count -gt 0 -and $aggregate.fail_count -gt 0)
    $aggregate.failed = ($aggregate.fail_count -gt 0)
    $scenarioAggregate += [pscustomobject]$aggregate
}

# Any non-zero scenario exit fails the suite (0/1 flag, not numeric max — see the
# per-iteration note above on negative crash codes).
$finalExitCode = 0
foreach ($result in $allResults) {
    if ([int]$result.final_exit_code -ne 0) {
        $finalExitCode = 1
    }
}

$flakyScenarioIds = @($scenarioAggregate | Where-Object { [bool]$_.flaky } | Select-Object -ExpandProperty scenario_id)
$failedScenarioIds = @($scenarioAggregate | Where-Object { [bool]$_.failed } | Select-Object -ExpandProperty scenario_id)
$suiteCompletedUtc = (Get-Date).ToUniversalTime()
$suiteElapsedMsec = [int][Math]::Round(($suiteCompletedUtc - $suiteStartedUtc).TotalMilliseconds)

# Disjoint, scenario_id-keyed classification for the stats: failed_both WINS over recovered (a
# scenario that ever failed both passes is genuinely broken). This keeps the two lists disjoint
# even when RepeatCount>1 lands the same scenario in both across iterations, so the aggregator's
# recovery_rate = |recovered_on_rerun| / |failed_parallel| stays well-defined.
$failedBothFinal = @($failedBothIds | Sort-Object -Unique)
$recoveredFinal = @($recoveredIds | Sort-Object -Unique | Where-Object { $_ -notin $failedBothFinal })
$failedParallelFinal = @($failedParallelIds | Sort-Object -Unique)

$suiteJsonPath = Join-Path $suiteRunPath "suite.json"
$suite = [ordered]@{
    suite_run_id = $suiteRunId
    suite_artifact_path = Convert-ToProjectRelativePath -Path $suiteRunPath -ResolvedProjectPath $resolvedProjectPath
    suite_summary_path = Convert-ToProjectRelativePath -Path $suiteJsonPath -ResolvedProjectPath $resolvedProjectPath
    scenario_directory = Convert-ToProjectRelativePath -Path $resolvedScenarioDirectory -ResolvedProjectPath $resolvedProjectPath
    repeat_count = $RepeatCount
    max_parallel = $MaxParallel
    iteration_count = $iterations.Count
    suite_status = Get-SuiteStatus -HasFailures ($failedScenarioIds.Count -gt 0) -HasFlakyScenarios ($flakyScenarioIds.Count -gt 0)
    final_exit_code = $finalExitCode
    scenario_count = $scenarioFiles.Count
    total_scenario_runs = $allResults.Count
    passed_count = @($allResults | Where-Object { [int]$_.final_exit_code -eq 0 }).Count
    failed_count = @($allResults | Where-Object { [int]$_.final_exit_code -ne 0 }).Count
    passed_iteration_count = @($iterations | Where-Object { [int]$_.final_exit_code -eq 0 }).Count
    failed_iteration_count = @($iterations | Where-Object { [int]$_.final_exit_code -ne 0 }).Count
    flaky_scenario_ids = $flakyScenarioIds
    failed_scenario_ids = $failedScenarioIds
    keep_latest_per_scenario = $KeepLatestPerScenario
    keep_latest_suite_runs = $KeepLatestSuiteRuns
    started_utc = $suiteStartedUtc.ToString("o")
    completed_utc = $suiteCompletedUtc.ToString("o")
    elapsed_msec = $suiteElapsedMsec
    parallel_phase_sec = [math]::Round($parallelMsecTotal / 1000, 2)
    rerun_phase_sec = [math]::Round($rerunMsecTotal / 1000, 2)
    rerun_verdict = $RerunVerdict
    recovered_on_rerun = $recoveredFinal
    failed_both = $failedBothFinal
    scenario_aggregate = $scenarioAggregate
    iterations = $iterations
}

$suite | ConvertTo-Json -Depth 20 | Set-Content -Path $suiteJsonPath -Encoding utf8

# Append a per-run efficiency record to the project's append-only timing log. Kept project-relative
# (under the same artifacts root as the suites) so the kit stays game-agnostic, and stamped with
# host/cores so records are never mixed across machines. A shared aggregator compares this against
# any other suite's records to answer "is parallel (with reruns) worth it?".
$statsDir = Join-Path $artifactsRoot "stats"
$null = New-Item -ItemType Directory -Path $statsDir -Force
$statsRecord = [ordered]@{
    timestamp          = (Get-Date).ToUniversalTime().ToString("o")
    suite              = "pure"
    suite_run_id       = $suiteRunId
    host               = [System.Environment]::MachineName
    cores              = [System.Environment]::ProcessorCount
    max_parallel       = $MaxParallel
    scenario_count     = $scenarioFiles.Count
    parallel_phase_sec = [math]::Round($parallelMsecTotal / 1000, 2)
    rerun_phase_sec    = [math]::Round($rerunMsecTotal / 1000, 2)
    total_sec          = [math]::Round(($parallelMsecTotal + $rerunMsecTotal) / 1000, 2)
    sum_scenario_sec   = [math]::Round($sumScenarioSecTotal, 2)
    failed_parallel    = $failedParallelFinal
    recovered_on_rerun = $recoveredFinal
    failed_both        = $failedBothFinal
    verdict_policy     = $RerunVerdict
    suite_status       = $suite.suite_status
}
($statsRecord | ConvertTo-Json -Depth 6 -Compress) | Add-Content -Path (Join-Path $statsDir "test_timings.jsonl") -Encoding utf8

& $pruneScriptPath -ProjectPath $resolvedProjectPath -KeepLatestPerScenario $KeepLatestPerScenario -KeepLatestSuiteRuns $KeepLatestSuiteRuns -ScenarioDirectories $resolvedScenarioDirectory | Out-Null

Write-Output ("SUITEARTIFACTS " + $suiteRunPath)
Write-Output ("SUITE " + ($suite | ConvertTo-Json -Depth 10 -Compress))

exit $finalExitCode
