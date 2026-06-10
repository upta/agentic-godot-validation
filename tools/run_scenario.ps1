param(
    [string]$Scenario = "",
    [string]$ProjectPath = $(
        $root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
        if (Test-Path (Join-Path $root "project.godot")) { $root }
        elseif (Test-Path (Join-Path $root "client" "project.godot")) { Join-Path $root "client" }
        else { $root }
    ),
    [string]$GodotExe = $env:GODOT_EXE,
    [int]$Screen = -1,
    [int]$KeepLatestPerScenario = 10,
    [switch]$SkipArtifactPrune
)

$ErrorActionPreference = "Stop"

function Resolve-GodotExe {
    param([string]$RequestedPath)

    if ($RequestedPath -and (Test-Path $RequestedPath)) {
        return (Resolve-Path $RequestedPath).Path
    }

    $command = Get-Command godot.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    throw "Could not locate godot.exe. Set GODOT_EXE or put Godot on PATH."
}

function Resolve-ScenarioPath {
    param(
        [string]$RequestedScenario,
        [string]$ResolvedProjectPath
    )

    if ([string]::IsNullOrWhiteSpace($RequestedScenario)) {
        $defaultCandidates = @(
            "validation/scenarios/move_up_smoke.json",
            "examples/minimal_poc/validation/scenarios/move_up_smoke.json"
        )

        foreach ($candidate in $defaultCandidates) {
            $candidatePath = Join-Path $ResolvedProjectPath $candidate
            if (Test-Path $candidatePath) {
                return (Resolve-Path $candidatePath).Path
            }
        }

        throw "Could not locate a default scenario contract under validation/scenarios or examples/minimal_poc/validation/scenarios."
    }

    if ([System.IO.Path]::IsPathRooted($RequestedScenario)) {
        return (Resolve-Path $RequestedScenario).Path
    }

    $projectRelativePath = Join-Path $ResolvedProjectPath $RequestedScenario
    if (Test-Path $projectRelativePath) {
        return (Resolve-Path $projectRelativePath).Path
    }

    $repoRoot = Split-Path $ResolvedProjectPath -Parent
    $repoRelativePath = Join-Path $repoRoot $RequestedScenario
    if (Test-Path $repoRelativePath) {
        return (Resolve-Path $repoRelativePath).Path
    }

    return (Resolve-Path $projectRelativePath).Path
}

function Convert-ToResPath {
    param(
        [string]$AbsolutePath,
        [string]$ResolvedProjectPath
    )

    $projectRoot = [System.IO.Path]::GetFullPath($ResolvedProjectPath)
    $fullPath = [System.IO.Path]::GetFullPath($AbsolutePath)
    if (-not $fullPath.StartsWith($projectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath
    }

    $relativePath = $fullPath.Substring($projectRoot.Length).TrimStart("\", "/")
    return "res://" + ($relativePath -replace "\\", "/")
}

function Get-ScenarioContract {
    param([string]$ScenarioFile)
    return Get-Content -Path $ScenarioFile -Raw | ConvertFrom-Json -AsHashtable
}

$resolvedProjectPath = (Resolve-Path $ProjectPath).Path
$resolvedScenarioPath = Resolve-ScenarioPath -RequestedScenario $Scenario -ResolvedProjectPath $resolvedProjectPath
$scenarioContract = Get-ScenarioContract -ScenarioFile $resolvedScenarioPath
$resolvedScenarioDirectory = Split-Path -Path $resolvedScenarioPath -Parent
$scenarioId = [string]$scenarioContract.scenario_id
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$runArtifactsPath = Join-Path $resolvedProjectPath (Join-Path "artifacts" (Join-Path $scenarioId $timestamp))
$null = New-Item -ItemType Directory -Path (Join-Path $runArtifactsPath "screenshots") -Force

$godotPath = Resolve-GodotExe -RequestedPath $GodotExe
$resScenarioPath = Convert-ToResPath -AbsolutePath $resolvedScenarioPath -ResolvedProjectPath $resolvedProjectPath
$consoleLogPath = Join-Path $runArtifactsPath "console.log"

$arguments = @(
    "--path", $resolvedProjectPath,
    "--log-file", $consoleLogPath
)

if ($Screen -ge 0) {
    $arguments += @("--screen", $Screen.ToString())
}

$arguments += @(
    "--",
    "--test-mode",
    "--scenario", $resScenarioPath,
    "--artifacts", $runArtifactsPath
)

$process = Start-Process -FilePath $godotPath -ArgumentList $arguments -WorkingDirectory $resolvedProjectPath -Wait -PassThru
$engineExitCode = $process.ExitCode

$requiredFiles = @($scenarioContract.artifact_contract.required_files)
$missingArtifacts = @()
foreach ($requiredFile in $requiredFiles) {
    $artifactPath = Join-Path $runArtifactsPath $requiredFile
    if (-not (Test-Path $artifactPath)) {
        $missingArtifacts += $requiredFile
    }
}

$summaryPath = Join-Path $runArtifactsPath "summary.json"
$summary = $null
if (Test-Path $summaryPath) {
    $summary = Get-Content -Path $summaryPath -Raw | ConvertFrom-Json -AsHashtable
}

$finalExitCode = $engineExitCode
if ($finalExitCode -eq 0 -and $missingArtifacts.Count -gt 0) {
    $finalExitCode = 4
}

$status = if ($summary) { [string]$summary.status } else { if ($finalExitCode -eq 0) { "pass" } else { "failed" } }
if ($finalExitCode -eq 4 -and $missingArtifacts.Count -gt 0) {
    $status = "artifact_generation_error"
}

$result = [ordered]@{
    scenario_id = $scenarioId
    status = $status
    engine_exit_code = $engineExitCode
    final_exit_code = $finalExitCode
    artifact_path = $runArtifactsPath
    missing_artifacts = $missingArtifacts
}

if (-not $SkipArtifactPrune) {
    try {
        $pruneScriptPath = Join-Path $PSScriptRoot "prune_artifacts.ps1"
        & $pruneScriptPath -ProjectPath $resolvedProjectPath -KeepLatestPerScenario $KeepLatestPerScenario -ScenarioDirectories $resolvedScenarioDirectory | Out-Null
    }
    catch {
        Write-Warning ("Artifact pruning failed: " + $_.Exception.Message)
    }
}

Write-Output ("RESULT " + ($result | ConvertTo-Json -Compress))
Write-Output ("ARTIFACTS " + $runArtifactsPath)

exit $finalExitCode