[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ProjectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [int]$KeepLatestPerScenario = 10,
    [int]$KeepLatestSuiteRuns = 10,
    [switch]$RemoveUnknownScenarioDirs = $true,
    [string[]]$ScenarioDirectories = @()
)

$ErrorActionPreference = "Stop"

function Resolve-ScenarioDirectories {
    param(
        [string]$ResolvedProjectPath,
        [string[]]$RequestedScenarioDirectories = @()
    )

    $candidateDirectories = @()
    if ($RequestedScenarioDirectories -and $RequestedScenarioDirectories.Count -gt 0) {
        foreach ($requestedScenarioDirectory in $RequestedScenarioDirectories) {
            if ([string]::IsNullOrWhiteSpace($requestedScenarioDirectory)) {
                continue
            }

            $candidatePath = $requestedScenarioDirectory
            if (-not [System.IO.Path]::IsPathRooted($candidatePath)) {
                $candidatePath = Join-Path $ResolvedProjectPath $candidatePath
            }

            if (-not (Test-Path $candidatePath)) {
                throw "Scenario directory does not exist: $requestedScenarioDirectory"
            }

            $candidateDirectories += (Resolve-Path $candidatePath).Path
        }
    }
    else {
        $candidateDirectories = @(
            Join-Path $ResolvedProjectPath "validation/scenarios",
            Join-Path $ResolvedProjectPath "examples/minimal_poc/validation/scenarios"
        )
    }

    $resolvedScenarioDirectories = @()
    foreach ($candidateDirectory in $candidateDirectories) {
        if (-not (Test-Path $candidateDirectory)) {
            continue
        }

        $resolvedCandidateDirectory = (Resolve-Path $candidateDirectory).Path
        $scenarioFile = Get-ChildItem -Path $resolvedCandidateDirectory -Filter *.json -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $scenarioFile) {
            continue
        }

        if ($resolvedScenarioDirectories -notcontains $resolvedCandidateDirectory) {
            $resolvedScenarioDirectories += $resolvedCandidateDirectory
        }
    }

    return $resolvedScenarioDirectories
}

function Get-ScenarioContracts {
    param(
        [string]$ResolvedProjectPath,
        [string[]]$RequestedScenarioDirectories = @()
    )

    $resolvedScenarioDirectories = @(Resolve-ScenarioDirectories -ResolvedProjectPath $ResolvedProjectPath -RequestedScenarioDirectories $RequestedScenarioDirectories)
    if ($resolvedScenarioDirectories.Count -eq 0) {
        return @()
    }

    $contracts = @()
    $seenScenarioIds = @{}

    foreach ($resolvedScenarioDirectory in $resolvedScenarioDirectories) {
        $scenarioFiles = Get-ChildItem -Path $resolvedScenarioDirectory -Filter *.json -File -ErrorAction SilentlyContinue
        foreach ($scenarioFile in $scenarioFiles) {
            $contract = Get-Content -Path $scenarioFile.FullName -Raw | ConvertFrom-Json -AsHashtable
            if ($null -eq $contract -or -not $contract.ContainsKey("scenario_id")) {
                continue
            }

            $scenarioId = [string]$contract.scenario_id
            if ([string]::IsNullOrWhiteSpace($scenarioId) -or $seenScenarioIds.ContainsKey($scenarioId)) {
                continue
            }

            $seenScenarioIds[$scenarioId] = $true
            $contracts += [pscustomobject]@{
                ScenarioId = $scenarioId
                FilePath = $scenarioFile.FullName
            }
        }
    }

    return $contracts
}

function Remove-ArtifactDirectory {
    param(
        [System.IO.DirectoryInfo]$Directory,
        [string]$Reason
    )

    if ($PSCmdlet.ShouldProcess($Directory.FullName, "Remove artifact directory ($Reason)")) {
        try {
            Remove-Item -Path $Directory.FullName -Recurse -Force -ErrorAction Stop
        }
        catch {
            # A transiently-locked file (e.g. a console.log a just-exited Godot or an AV scan still
            # holds on Windows) must NOT abort the whole prune — and, since callers run with
            # $ErrorActionPreference='Stop', must not take the suite down before it emits its
            # SUITE/exit/stats output. Warn and leave the dir for the next prune to reclaim.
            Write-Warning ("Could not remove artifact dir '{0}' ({1}): {2}" -f $Directory.FullName, $Reason, $_.Exception.Message)
            return [pscustomobject]@{
                path = $Directory.FullName
                reason = ("{0}:removal_failed" -f $Reason)
            }
        }
    }

    return [pscustomobject]@{
        path = $Directory.FullName
        reason = $Reason
    }
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

function Get-ScenarioManifestEntry {
    param(
        [System.IO.DirectoryInfo]$ScenarioDirectory,
        [string]$ResolvedProjectPath
    )

    $runDirectories = Get-ChildItem -Path $ScenarioDirectory.FullName -Directory | Sort-Object Name -Descending
    $entry = [ordered]@{
        scenario_id = [string]$ScenarioDirectory.Name
        artifact_dir = Convert-ToProjectRelativePath -Path $ScenarioDirectory.FullName -ResolvedProjectPath $ResolvedProjectPath
        run_count = $runDirectories.Count
        latest = $null
    }

    if ($runDirectories.Count -eq 0) {
        return $entry
    }

    $latestRun = $runDirectories[0]
    $summaryPath = Join-Path $latestRun.FullName "summary.json"
    $consoleLogPath = Join-Path $latestRun.FullName "console.log"
    $summary = $null
    if (Test-Path $summaryPath) {
        $summary = Get-Content -Path $summaryPath -Raw | ConvertFrom-Json -AsHashtable
    }

    $entry.latest = [ordered]@{
        run_id = [string]$latestRun.Name
        artifact_path = Convert-ToProjectRelativePath -Path $latestRun.FullName -ResolvedProjectPath $ResolvedProjectPath
        summary_path = if (Test-Path $summaryPath) { Convert-ToProjectRelativePath -Path $summaryPath -ResolvedProjectPath $ResolvedProjectPath } else { $null }
        console_log_path = if (Test-Path $consoleLogPath) { Convert-ToProjectRelativePath -Path $consoleLogPath -ResolvedProjectPath $ResolvedProjectPath } else { $null }
        status = if ($null -ne $summary) { [string]$summary.status } else { $null }
        exit_code = if ($null -ne $summary -and $summary.ContainsKey("exit_code")) { $summary.exit_code } elseif ($null -ne $summary -and $summary.ContainsKey("result") -and $summary.result -and $summary.result.ContainsKey("exit_code")) { $summary.result.exit_code } else { $null }
        message = if ($null -ne $summary) { [string]$summary.message } else { $null }
        created_utc = $latestRun.CreationTimeUtc.ToString("o")
        last_write_utc = $latestRun.LastWriteTimeUtc.ToString("o")
    }

    return $entry
}

function Write-ArtifactManifests {
    param(
        [string]$ArtifactsRoot,
        [string]$ResolvedProjectPath,
        [int]$KeepLatestPerScenario
    )

    $index = [ordered]@{
        updated_utc = (Get-Date).ToUniversalTime().ToString("o")
        kept_latest_per_scenario = $KeepLatestPerScenario
        scenarios = [ordered]@{}
    }

    $scenarioDirectories = Get-ChildItem -Path $ArtifactsRoot -Directory | Sort-Object Name
    foreach ($scenarioDirectory in $scenarioDirectories) {
        if ([string]$scenarioDirectory.Name -eq "suites" -or [string]$scenarioDirectory.Name -eq "stats") {
            continue
        }

        $entry = Get-ScenarioManifestEntry -ScenarioDirectory $scenarioDirectory -ResolvedProjectPath $ResolvedProjectPath
        $index.scenarios[[string]$scenarioDirectory.Name] = $entry

        $latestManifestPath = Join-Path $scenarioDirectory.FullName "latest.json"
        $entry | ConvertTo-Json -Depth 10 | Set-Content -Path $latestManifestPath -Encoding utf8
    }

    $indexPath = Join-Path $ArtifactsRoot "index.json"
    $index | ConvertTo-Json -Depth 10 | Set-Content -Path $indexPath -Encoding utf8
}

function Get-SuiteManifestEntry {
    param(
        [System.IO.DirectoryInfo]$SuiteRunDirectory,
        [string]$ResolvedProjectPath
    )

    $suiteSummaryPath = Join-Path $SuiteRunDirectory.FullName "suite.json"
    $suiteSummary = $null
    if (Test-Path $suiteSummaryPath) {
        $suiteSummary = Get-Content -Path $suiteSummaryPath -Raw | ConvertFrom-Json -AsHashtable
    }

    return [ordered]@{
        suite_run_id = [string]$SuiteRunDirectory.Name
        artifact_path = Convert-ToProjectRelativePath -Path $SuiteRunDirectory.FullName -ResolvedProjectPath $ResolvedProjectPath
        summary_path = if (Test-Path $suiteSummaryPath) { Convert-ToProjectRelativePath -Path $suiteSummaryPath -ResolvedProjectPath $ResolvedProjectPath } else { $null }
        suite_status = if ($null -ne $suiteSummary -and $suiteSummary.ContainsKey("suite_status")) { [string]$suiteSummary.suite_status } elseif ($null -ne $suiteSummary -and $suiteSummary.ContainsKey("status")) { [string]$suiteSummary.status } else { $null }
        final_exit_code = if ($null -ne $suiteSummary -and $suiteSummary.ContainsKey("final_exit_code")) { $suiteSummary.final_exit_code } else { $null }
        repeat_count = if ($null -ne $suiteSummary -and $suiteSummary.ContainsKey("repeat_count")) { $suiteSummary.repeat_count } else { $null }
        iteration_count = if ($null -ne $suiteSummary -and $suiteSummary.ContainsKey("iteration_count")) { $suiteSummary.iteration_count } else { $null }
        scenario_count = if ($null -ne $suiteSummary -and $suiteSummary.ContainsKey("scenario_count")) { $suiteSummary.scenario_count } else { $null }
        failed_count = if ($null -ne $suiteSummary -and $suiteSummary.ContainsKey("failed_count")) { $suiteSummary.failed_count } else { $null }
        flaky_scenario_count = if ($null -ne $suiteSummary -and $suiteSummary.ContainsKey("flaky_scenario_ids") -and $suiteSummary.flaky_scenario_ids) { @($suiteSummary.flaky_scenario_ids).Count } else { 0 }
        started_utc = if ($null -ne $suiteSummary -and $suiteSummary.ContainsKey("started_utc")) { Convert-ToManifestTimestamp -Value $suiteSummary.started_utc } else { $null }
        completed_utc = if ($null -ne $suiteSummary -and $suiteSummary.ContainsKey("completed_utc")) { Convert-ToManifestTimestamp -Value $suiteSummary.completed_utc } else { $null }
        created_utc = $SuiteRunDirectory.CreationTimeUtc.ToString("o")
        last_write_utc = $SuiteRunDirectory.LastWriteTimeUtc.ToString("o")
    }
}

function Write-SuiteManifests {
    param(
        [string]$ArtifactsRoot,
        [string]$ResolvedProjectPath,
        [int]$KeepLatestSuiteRuns
    )

    $suiteRoot = Join-Path $ArtifactsRoot "suites"
    $latestSuiteManifestPath = Join-Path $ArtifactsRoot "latest_suite.json"

    if (-not (Test-Path $suiteRoot)) {
        if (Test-Path $latestSuiteManifestPath) {
            Remove-Item -Path $latestSuiteManifestPath -Force
        }
        return
    }

    $suiteRunDirectories = Get-ChildItem -Path $suiteRoot -Directory | Sort-Object Name -Descending
    $suiteIndex = [ordered]@{
        updated_utc = (Get-Date).ToUniversalTime().ToString("o")
        keep_latest_suite_runs = $KeepLatestSuiteRuns
        suite_root_dir = Convert-ToProjectRelativePath -Path $suiteRoot -ResolvedProjectPath $ResolvedProjectPath
        run_count = $suiteRunDirectories.Count
        latest = $null
        runs = @()
    }

    foreach ($suiteRunDirectory in $suiteRunDirectories) {
        $entry = Get-SuiteManifestEntry -SuiteRunDirectory $suiteRunDirectory -ResolvedProjectPath $ResolvedProjectPath
        if ($null -eq $suiteIndex.latest) {
            $suiteIndex.latest = $entry
        }
        $suiteIndex.runs += $entry
    }

    $suiteIndexPath = Join-Path $suiteRoot "index.json"
    $suiteIndex | ConvertTo-Json -Depth 10 | Set-Content -Path $suiteIndexPath -Encoding utf8

    $latestSuiteManifest = [ordered]@{
        updated_utc = (Get-Date).ToUniversalTime().ToString("o")
        keep_latest_suite_runs = $KeepLatestSuiteRuns
        suite_root_dir = Convert-ToProjectRelativePath -Path $suiteRoot -ResolvedProjectPath $ResolvedProjectPath
        run_count = $suiteRunDirectories.Count
        latest = $suiteIndex.latest
    }
    $latestSuiteManifest | ConvertTo-Json -Depth 10 | Set-Content -Path $latestSuiteManifestPath -Encoding utf8
}

function Convert-ToManifestTimestamp {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [DateTime]) {
        return $Value.ToUniversalTime().ToString("o")
    }

    return [string]$Value
}

$resolvedProjectPath = (Resolve-Path $ProjectPath).Path
$artifactsRoot = Join-Path $resolvedProjectPath "artifacts"
if (-not (Test-Path $artifactsRoot)) {
    Write-Output ("PRUNE " + (([ordered]@{ removed = @(); kept_latest_per_scenario = $KeepLatestPerScenario }) | ConvertTo-Json -Compress))
    return
}

$scenarioContracts = @(Get-ScenarioContracts -ResolvedProjectPath $resolvedProjectPath -RequestedScenarioDirectories $ScenarioDirectories)
$activeScenarioIds = @(
    $scenarioContracts |
        ForEach-Object { [string]$_.ScenarioId } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
)

$allowUnknownScenarioDirectoryRemoval = [bool]$RemoveUnknownScenarioDirs -and $scenarioContracts.Count -gt 0
if ([bool]$RemoveUnknownScenarioDirs -and -not $allowUnknownScenarioDirectoryRemoval) {
    Write-Warning "Skipping unknown scenario directory removal because no scenario contracts were discovered."
}

$removed = @()
$artifactScenarioDirectories = Get-ChildItem -Path $artifactsRoot -Directory | Sort-Object Name
foreach ($artifactScenarioDirectory in $artifactScenarioDirectories) {
    $scenarioId = [string]$artifactScenarioDirectory.Name

    # "suites" holds suite-run records; "stats" holds the append-only timing log. Both are
    # reserved (not scenario artifact dirs), so never prune them as "unknown scenarios".
    if ($scenarioId -eq "suites" -or $scenarioId -eq "stats") {
        continue
    }

    $isActiveScenario = $activeScenarioIds -contains $scenarioId

    if (-not $isActiveScenario) {
        if ($allowUnknownScenarioDirectoryRemoval) {
            $removed += Remove-ArtifactDirectory -Directory $artifactScenarioDirectory -Reason "unknown_scenario"
        }
        continue
    }

    if ($KeepLatestPerScenario -lt 0) {
        throw "KeepLatestPerScenario must be 0 or greater."
    }

    $runDirectories = Get-ChildItem -Path $artifactScenarioDirectory.FullName -Directory | Sort-Object Name -Descending
    if ($KeepLatestPerScenario -eq 0) {
        $directoriesToRemove = $runDirectories
    }
    else {
        $directoriesToRemove = $runDirectories | Select-Object -Skip $KeepLatestPerScenario
    }

    foreach ($runDirectory in $directoriesToRemove) {
        $removed += Remove-ArtifactDirectory -Directory $runDirectory -Reason ("retention_exceeded:{0}" -f $scenarioId)
    }
}

if ($KeepLatestSuiteRuns -lt 0) {
    throw "KeepLatestSuiteRuns must be 0 or greater."
}

$suiteRoot = Join-Path $artifactsRoot "suites"
if (Test-Path $suiteRoot) {
    $suiteRunDirectories = Get-ChildItem -Path $suiteRoot -Directory | Sort-Object Name -Descending
    if ($KeepLatestSuiteRuns -eq 0) {
        $suiteDirectoriesToRemove = $suiteRunDirectories
    }
    else {
        $suiteDirectoriesToRemove = $suiteRunDirectories | Select-Object -Skip $KeepLatestSuiteRuns
    }

    foreach ($suiteRunDirectory in $suiteDirectoriesToRemove) {
        $removed += Remove-ArtifactDirectory -Directory $suiteRunDirectory -Reason "suite_retention_exceeded"
    }
}

Write-ArtifactManifests -ArtifactsRoot $artifactsRoot -ResolvedProjectPath $resolvedProjectPath -KeepLatestPerScenario $KeepLatestPerScenario
Write-SuiteManifests -ArtifactsRoot $artifactsRoot -ResolvedProjectPath $resolvedProjectPath -KeepLatestSuiteRuns $KeepLatestSuiteRuns

Write-Output ("PRUNE " + (([ordered]@{ removed = $removed; kept_latest_per_scenario = $KeepLatestPerScenario; kept_latest_suite_runs = $KeepLatestSuiteRuns; remove_unknown_scenario_dirs = $allowUnknownScenarioDirectoryRemoval; scenario_contract_count = $scenarioContracts.Count }) | ConvertTo-Json -Compress))
