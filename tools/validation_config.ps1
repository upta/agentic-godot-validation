# Loads the consumer repo's validation.config.psd1 (a PowerShell data file — read with
# Import-PowerShellDataFile, never Invoke-Expression), applies documented defaults, and returns a
# resolved config hashtable. Dot-sourced by run_stdb_scenarios.ps1 / validate_all.ps1 so there is
# one source of truth for every project-specific knob (paths, module/db names, the runner<->client
# env-var contract, token/ephemeral naming, artifacts location, recycle + timing tuning).
#
# Every knob has a default, so a project laid out by convention (Godot client under src/ or
# client/, STDB module under server/) works with NO config file. The file only overrides.
#
# The env-var NAMES (Uri/Db/ClientId) default to kit-fixed STDB_TEST_* on purpose: they are read
# by both this PowerShell runner AND the C# client (DbManager), so a fixed name keeps the C#
# connection helper copy-paste-stable across every consumer. Only db/token/path names derive from
# AppName.
function Import-ValidationConfig {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $configPath = Join-Path $RepoRoot "validation.config.psd1"
    $user = @{}
    if (Test-Path $configPath) {
        $user = Import-PowerShellDataFile -Path $configPath
    }

    function Pick { param($Value, $Default) if ($null -ne $Value -and "$Value" -ne "") { return $Value } return $Default }

    # Auto-detect the Godot client root: a project.godot at the repo root (single-root layout),
    # else src/, else client/.
    $clientRoot = [string](Pick $user.ClientRoot $(
            $detected = $null
            foreach ($c in @('.', 'src', 'client')) {
                $p = if ($c -eq '.') { $RepoRoot } else { Join-Path $RepoRoot $c }
                if (Test-Path (Join-Path $p 'project.godot')) { $detected = $c; break }
            }
            if ($detected) { $detected } else { 'src' }
        ))

    $appName = [string](Pick $user.AppName (Split-Path $RepoRoot -Leaf))
    $serverRoot = [string](Pick $user.ServerRoot 'server')
    $modulePath = [string](Pick $user.ModulePath './src')
    $moduleName = [string](Pick $user.ModuleName $appName)
    $scenariosStdbDir = [string](Pick $user.ScenariosStdbDir ("$clientRoot/validation/scenarios_stdb"))
    $artifactsRoot = [string](Pick $user.ArtifactsRoot ("$clientRoot/artifacts"))
    $tokenPrefix = [string](Pick $user.TokenPrefix (".$appName"))
    $ephemeralPrefix = [string](Pick $user.EphemeralPrefix ("$appName-test"))
    $serverRecycleEvery = [int](Pick $user.ServerRecycleEvery 0)

    $wasmGlob = if ($user.WasmGlob) { @($user.WasmGlob) } else { @('*.opt.wasm', '*_for-publish.wasm') }

    # Env-var contract (runner sets these; the C# client reads them). Fixed names by default.
    $envCfg = @{ Uri = 'STDB_TEST_URI'; Db = 'STDB_TEST_DB'; ClientId = 'STDB_TEST_CLIENT_ID' }
    if ($user.Env) { foreach ($k in $user.Env.Keys) { $envCfg[[string]$k] = [string]$user.Env[$k] } }

    # Timing-report thresholds (the aggregator's "is parallel worth it?" warnings).
    $timings = @{ PureMinSpeedup = 2.0; StdbMinSpeedup = 1.5; PureMaxRecoveryRate = 0.6; StdbMaxRecoveryRate = 0.85 }
    if ($user.Timings) { foreach ($k in $user.Timings.Keys) { $timings[[string]$k] = $user.Timings[$k] } }

    return [ordered]@{
        RepoRoot           = $RepoRoot
        AppName            = $appName
        ClientRoot         = $clientRoot
        ServerRoot         = $serverRoot
        ModulePath         = $modulePath
        ModuleName         = $moduleName
        ScenariosStdbDir   = $scenariosStdbDir
        ArtifactsRoot      = $artifactsRoot
        WasmGlob           = $wasmGlob
        Env                = $envCfg
        TokenPrefix        = $tokenPrefix
        EphemeralPrefix    = $ephemeralPrefix
        ServerRecycleEvery = $serverRecycleEvery
        Timings            = $timings
        # Absolute, resolved convenience paths.
        ClientDir          = (Join-Path $RepoRoot $clientRoot)
        ServerDir          = (Join-Path $RepoRoot $serverRoot)
        ArtifactsDir       = (Join-Path $RepoRoot $artifactsRoot)
        ScenariosStdbPath  = (Join-Path $RepoRoot $scenariosStdbDir)
    }
}
