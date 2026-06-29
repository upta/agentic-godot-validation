# Runs the SpacetimeDB-backed validation scenarios (<ScenariosStdbDir>, default
# <ClientRoot>/validation/scenarios_stdb) against a real local SpacetimeDB instance. Each scenario
# gets its OWN ephemeral database so state and config can never leak between scenarios.
#
# All project-specific values (client/server roots, module + dev-DB name, the runner<->client env
# vars, token/ephemeral naming, artifacts path, recycle cadence) come from the consumer repo's
# validation.config.psd1 via tools/validation_config.ps1 — this script is project-agnostic.
#
# Scenarios run in PARALLEL (-MaxParallel, default 2). The module is built ONCE up front, then each
# worker publishes that prebuilt wasm to its own database via `spacetime publish --bin-path` (no
# rebuild, no cargo lock — safe to run concurrently) and drives the Godot client in its own process.
# Per-worker isolation comes from a private environment block (unique <Env.Db> + <Env.ClientId> ->
# isolated <TokenPrefix>-<id> token file), never the shared process environment.
#
#   ./tools/run_stdb_scenarios.ps1                  # full STDB suite (parallel)
#   ./tools/run_stdb_scenarios.ps1 -MaxParallel 1   # serial (for debugging)
#   ./tools/run_stdb_scenarios.ps1 -Scenario <ClientRoot>/validation/scenarios_stdb/<name>.json
#   ./tools/run_stdb_scenarios.ps1 -KeepDatabase    # keep DBs of failed scenarios
#
# Constrained-host survivability: `spacetime delete` frees a database's catalog entry but LEAKS its
# on-disk replica dir, so the data dir grows ~+1 replica/scenario and compounds across runs until
# the local server can't start (publish_failed cascade). -ServerRecycleEvery N RESETS the server
# every N scenarios — stop, `spacetime server clear` (the only bulk reclaim), restart — plus once
# before the run (clears inherited debt) and once after (leaves the host clean, restoring the dev
# <ModuleName> DB from the prebuilt wasm). A plain restart would NOT help: the leaked replica dirs
# survive it. Default (0) AUTO-enables a safe interval for big full-suite runs and stays off for
# small/single/-KeepDatabase runs. This machinery is Windows + STDB-CLI specific; -NoServerRecycle
# disables it. (Verify the replica leak still exists on your STDB version before relying on it.)

param(
    [string]$Scenario = "",
    [string]$GodotExe = $env:GODOT_EXE,
    [string]$ServerUri = "http://localhost:3000",
    # Default 2: all clients share one local SpacetimeDB server, so it — not CPU — is the
    # bottleneck. Beyond ~2 concurrent clients the server lags: connected scenarios either fail an
    # assertion (a sync timeout — a REAL failure, reported honestly) or pass their assertions and
    # then crash on teardown (reported flaky/green, since the scenario validated). Raise for a
    # faster one-off, but expect reds as it saturates.
    [int]$MaxParallel = 2,
    [switch]$Record,
    [int]$RecordFps = 30,
    [switch]$KeepDatabase,
    # Skip the automatic serial re-run of parallel failures (debugging aid). The re-run is
    # DIAGNOSTIC ONLY and never changes the verdict (see stdb_suite_verdict.ps1), so disabling it
    # only removes the recovered/failed_both classification + its timing from the stats.
    [switch]$NoRerun,
    # Reset (stop + `spacetime server clear` + restart) the local server every N scenarios to
    # reclaim the on-disk replica storage `delete` leaks. 0 (default) = AUTO; a positive N forces
    # that interval; a negative N is off. A reset wipes ALL local databases, so it is disabled with
    # -KeepDatabase.
    [int]$ServerRecycleEvery = 0,
    [switch]$NoServerRecycle
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent

. (Join-Path $PSScriptRoot "stdb_suite_verdict.ps1")
. (Join-Path $PSScriptRoot "validation_config.ps1")
$config = Import-ValidationConfig -RepoRoot $repoRoot

$serverDir = $config.ServerDir
$clientDir = $config.ClientDir

if ($MaxParallel -lt 1) {
    throw "MaxParallel must be 1 or greater."
}

if (-not (Get-Command spacetime -ErrorAction SilentlyContinue)) {
    throw "spacetime CLI not found on PATH."
}

function Test-ServerUp {
    spacetime list --server local 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# The local server is a 3-process chain (spacetime.exe start -> spacetimedb-cli.exe start ->
# spacetimedb-standalone.exe). Recycling targets the standalone (holds the port + the leaked
# resources) and the `start` wrapper chain; short-lived `spacetime <cmd>` CLI calls (e.g. our own
# `list`/`publish`) never match `\bstart\b`, so they are not killed.
function Get-StdbServerProcess {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq "spacetimedb-standalone.exe" -or
        (($_.Name -eq "spacetime.exe" -or $_.Name -eq "spacetimedb-cli.exe") -and $_.CommandLine -match "\bstart\b")
    }
}

function Start-StdbServer {
    param([int]$TimeoutSec = 30)
    Start-Process spacetime -ArgumentList "start" -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not (Test-ServerUp)) {
        if ((Get-Date) -gt $deadline) {
            throw "SpacetimeDB server did not become ready within $TimeoutSec seconds."
        }
        Start-Sleep -Milliseconds 500
    }
}

function Stop-StdbServer {
    param([int]$TimeoutSec = 20)
    foreach ($p in @(Get-StdbServerProcess)) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop }
        catch { Write-Host ("  warn: could not kill pid {0} ({1}): {2}" -f $p.ProcessId, $p.Name, $_.Exception.Message) -ForegroundColor DarkYellow }
    }
    # Don't return until the server actually stops answering — otherwise a fresh `start` would
    # collide with the dying one on port 3000 (or silently keep the leaked instance alive).
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (Test-ServerUp) {
        if ((Get-Date) -gt $deadline) {
            throw "SpacetimeDB server still accepting connections ${TimeoutSec}s after kill — cannot safely recycle."
        }
        Start-Sleep -Milliseconds 300
    }
}

# Reclaim leaked replica storage. `spacetime delete` removes a database's CATALOG entry (so it
# stops `list`ing) but NEVER reclaims its on-disk replica dir — every publish leaks one. The only
# supported bulk reclaim is `server clear`, which requires the server STOPPED and wipes ALL local
# databases (incl. the dev <ModuleName> DB — restored from the prebuilt wasm at run end).
function Clear-StdbData {
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        spacetime server clear --yes *> $null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Milliseconds 400
    }
    throw "spacetime server clear failed after retries — cannot reclaim leaked replica storage."
}

# Reset the server: stop -> reclaim leaked replica storage -> start fresh. Called only at a batch
# barrier (no scenario in flight) so wiping all databases is safe. Reset time accrues to
# $script:recycleSw (excluded from the phase stopwatches) and bumps $script:recycleCount.
function Reset-StdbServer {
    param([string]$Reason = "")
    $suffix = if ($Reason) { " ($Reason)" } else { "" }
    Write-Host ("  resetting local SpacetimeDB server to reclaim leaked replica storage{0}..." -f $suffix) -ForegroundColor DarkCyan
    $script:recycleSw.Start()
    Stop-StdbServer
    Clear-StdbData
    Start-StdbServer
    $script:recycleSw.Stop()
    $script:recycleCount++
    Write-Host ("  server reset (#{0}); resuming." -f $script:recycleCount) -ForegroundColor DarkCyan
}

# Server lifecycle decision: start on demand, leave running.
if (-not (Test-ServerUp)) {
    Write-Host "Starting local SpacetimeDB server..."
    Start-StdbServer
}

# Remember whether the dev <ModuleName> DB exists so a reset run (which wipes it) can restore it at
# the end from the prebuilt wasm — preserving the pre-run "server has the dev DB" invariant.
$hadModule = [bool](spacetime list --server local 2>$null | Select-String -SimpleMatch -Quiet (" {0} " -f $config.ModuleName))

# Build the module ONCE. Each per-scenario publish then reuses this exact wasm via --bin-path, so
# publishes never rebuild and can run concurrently.
Write-Host "Building server module..."
Push-Location $serverDir
try {
    spacetime build --module-path $config.ModulePath
    if ($LASTEXITCODE -ne 0) {
        throw "spacetime build failed."
    }
}
finally {
    Pop-Location
}

# Locate the compiled wasm the build just produced (prefer the wasm-opt output that a normal
# publish would upload; fall back per the configured WasmGlob order). The .NET wasi build also
# emits the runtime `dotnet.wasm` alongside the module bundle — exclude it by name so a bare
# '*.wasm' fallback still resolves to the module on hosts without wasm-opt installed.
$moduleDir = Join-Path $serverDir ($config.ModulePath -replace '^\.[\\/]', '')
$wasmPath = $null
foreach ($pattern in $config.WasmGlob) {
    $candidate = Get-ChildItem $moduleDir -Recurse -Filter $pattern -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'dotnet.wasm' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($candidate) { $wasmPath = $candidate.FullName; break }
}
if (-not $wasmPath) {
    throw "Could not locate the compiled wasm under $moduleDir after build (looked for: $($config.WasmGlob -join ', '))."
}

if ($Scenario) {
    $resolved = if ([System.IO.Path]::IsPathRooted($Scenario)) {
        $Scenario
    }
    elseif (Test-Path (Join-Path $repoRoot $Scenario)) {
        Join-Path $repoRoot $Scenario
    }
    elseif (Test-Path (Join-Path $clientDir $Scenario)) {
        Join-Path $clientDir $Scenario
    }
    else {
        throw "Scenario not found: $Scenario"
    }
    $scenarioFiles = @(Get-Item $resolved)
}
else {
    if (-not (Test-Path $config.ScenariosStdbPath)) {
        throw "STDB scenario directory not found: $($config.ScenariosStdbPath)"
    }
    $scenarioFiles = @(
        Get-ChildItem $config.ScenariosStdbPath -Filter *.json -File | Sort-Object Name
    )
    if ($scenarioFiles.Count -eq 0) {
        throw "No scenario contracts found under $($config.ScenariosStdbPath)."
    }
}

$runStamp = Get-Date -Format "yyyyMMddHHmmss"
$isSingle = [bool]$Scenario
$runScenarioScript = Join-Path $PSScriptRoot "run_scenario.ps1"

# Build the work list up front so each scenario has a stable, unique database name and client id
# (-> isolated token file) regardless of completion order.
$work = @()
$index = 0
foreach ($scenarioFile in $scenarioFiles) {
    $index++
    $work += [pscustomobject]@{
        Index    = $index
        Name     = $scenarioFile.Name
        FullName = $scenarioFile.FullName
        Db       = "{0}-{1}-{2:d2}" -f $config.EphemeralPrefix, $runStamp, $index
        ClientId = "test-{0}-{1:d2}" -f $runStamp, $index
    }
}

# Resolve the effective server-reset interval. AUTO resets every 40 once a full suite exceeds 50
# scenarios; small/single runs stay off. -KeepDatabase forces off (a reset wipes all local DBs).
$configuredRecycle = if ($ServerRecycleEvery -ne 0) { $ServerRecycleEvery } else { $config.ServerRecycleEvery }
$recycleAutoThreshold = 50
$recycleAutoDefault = 40
$effectiveRecycleEvery = 0
$recycleMode = "off"
if ($NoServerRecycle) { $recycleMode = "off (disabled)" }
elseif ($KeepDatabase) { $recycleMode = "off (-KeepDatabase)" }
elseif ($configuredRecycle -gt 0) { $effectiveRecycleEvery = $configuredRecycle; $recycleMode = "explicit" }
elseif ($configuredRecycle -lt 0) { $recycleMode = "off (negative)" }
elseif (-not $isSingle -and $work.Count -gt $recycleAutoThreshold) { $effectiveRecycleEvery = $recycleAutoDefault; $recycleMode = "auto" }
if ($effectiveRecycleEvery -gt 0) {
    Write-Host ("Server reset ENABLED [{0}]: stop + ``spacetime server clear`` + restart every {1} scenarios (and once before/after the run) to reclaim leaked replica storage on constrained hosts." -f $recycleMode, $effectiveRecycleEvery) -ForegroundColor DarkCyan
}

# Split a work list into chunks of $size (a single chunk when $size <= 0 or the list fits). Each
# chunk runs to completion under -Parallel, then the server is reset between chunks. The leading
# commas stop PowerShell unrolling the array-of-arrays.
function Split-WorkIntoChunks {
    param([object[]]$items, [int]$size)
    $chunks = [System.Collections.ArrayList]::new()
    if ($size -le 0 -or $items.Count -le $size) {
        [void]$chunks.Add(@($items))
    }
    else {
        for ($i = 0; $i -lt $items.Count; $i += $size) {
            $hi = [Math]::Min($i + $size - 1, $items.Count - 1)
            [void]$chunks.Add(@($items[$i..$hi]))
        }
    }
    return , $chunks.ToArray()
}

# One scenario's full lifecycle: publish the prebuilt wasm to its OWN database, drive the client in
# an isolated env block, verdict by assertion status, delete the DB. Used by BOTH the parallel pass
# and the serial re-run, so there is exactly one source of truth for the per-scenario verdict.
function Invoke-StdbScenario {
    param(
        $item,
        [string]$wasmPath,
        [string]$ServerUri,
        [string]$runScenarioScript,
        [string]$GodotExe,
        [bool]$keepRequested,
        [bool]$isSingle,
        [bool]$record,
        [int]$recordFps,
        [string]$envUriName,
        [string]$envDbName,
        [string]$envClientIdName,
        [string]$tokenPrefix
    )

    $scenarioSw = [System.Diagnostics.Stopwatch]::StartNew()

    # 1) Publish the prebuilt wasm to this scenario's own database (concurrent-safe).
    & spacetime publish $item.Db --yes --server local --bin-path $wasmPath *> $null
    $publishOk = ($LASTEXITCODE -eq 0)

    $finalExit = 1
    $status = "publish_failed"
    $artifact = $null
    $capturedOutput = $null

    if ($publishOk) {
        # 2) Drive the client in its own process with an ISOLATED environment block. Cloning the
        #    parent env and overlaying keeps PATH/etc. intact while making the DB/identity selection
        #    private to this child (no shared $env: race).
        $childEnv = @{}
        foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
            if ($null -ne $entry.Key) { $childEnv[[string]$entry.Key] = [string]$entry.Value }
        }
        $childEnv[$envUriName] = $ServerUri
        $childEnv[$envDbName] = $item.Db
        $childEnv[$envClientIdName] = $item.ClientId

        $outFile = [System.IO.Path]::GetTempFileName()
        $errFile = [System.IO.Path]::GetTempFileName()
        $argList = @("-NoProfile", "-File", $runScenarioScript, "-Scenario", $item.FullName, "-SkipArtifactPrune")
        if ($GodotExe) { $argList += @("-GodotExe", $GodotExe) }
        if ($record) { $argList += @("-Record", "-RecordFps", $recordFps.ToString()) }

        try {
            $proc = Start-Process -FilePath "pwsh" -ArgumentList $argList -Environment $childEnv `
                -RedirectStandardOutput $outFile -RedirectStandardError $errFile -WindowStyle Hidden -PassThru
            $null = $proc.Handle  # cache handle so ExitCode is readable after exit
            $proc.WaitForExit()
            $procExit = $proc.ExitCode

            $capturedOutput = (Get-Content $outFile -Raw -ErrorAction SilentlyContinue)
            $resultLine = (Get-Content $outFile -ErrorAction SilentlyContinue | Where-Object { $_ -like "RESULT *" } | Select-Object -Last 1)
            if ($resultLine) {
                try {
                    $parsed = $resultLine.Substring(7) | ConvertFrom-Json
                    $finalExit = [int]$parsed.final_exit_code
                    $status = [string]$parsed.status
                    $artifact = [string]$parsed.artifact_path
                }
                catch {
                    $finalExit = $procExit
                    $status = if ($procExit -eq 0) { "pass" } else { "failed" }
                }
            }
            else {
                $finalExit = $procExit
                $status = if ($procExit -eq 0) { "pass" } else { "failed" }
            }
        }
        finally {
            Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
        }
    }

    # 3) Verdict by ASSERTION status, not process exit. The verifier writes summary.json (carried on
    #    the RESULT line as `status`) BEFORE the engine quits, so a scenario that asserts cleanly is
    #    status=='pass' regardless of a later teardown crash. A non-zero exit WITH status=='pass' is
    #    the shutdown crash seen under load — the scenario validated, so it is flaky (green), not a
    #    failure. Any other status is a real failure that must NOT be forgiven.
    $validated = ($status -eq "pass")
    $flaky = ($validated -and $finalExit -ne 0)   # passed assertions, crashed on teardown

    # Keep the DB only for genuine failures (or single-scenario debug runs) when asked.
    $keep = $keepRequested -and ((-not $validated) -or $isSingle)
    if ($keep) {
        Write-Host ("  keeping database '{0}' for inspection." -f $item.Db)
    }
    else {
        & spacetime delete $item.Db --server local --yes *> $null
    }

    # Remove this scenario's auth-token folder (<tokenPrefix>-<clientId>, written by the Godot
    # client's AuthToken.Init). Each is a throwaway identity for an ephemeral test DB that no longer
    # exists; uncleaned they pile up by the thousands in the home dir.
    $tokenDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) ("{0}-{1}" -f $tokenPrefix, $item.ClientId)
    if (Test-Path $tokenDir) { Remove-Item $tokenDir -Recurse -Force -ErrorAction SilentlyContinue }

    $label = if (-not $validated) { $status } elseif ($flaky) { "flaky ($status; teardown crash $finalExit)" } else { "pass" }
    $color = if (-not $validated) { "Red" } elseif ($flaky) { "Yellow" } else { "Green" }
    Write-Host ("  [{0}] {1} -> {2}" -f $item.Index, $item.Name, $label) -ForegroundColor $color

    # Surface full child output for real failures (and single-scenario debug runs).
    if (((-not $validated) -or $isSingle) -and -not [string]::IsNullOrWhiteSpace($capturedOutput)) {
        Write-Host ("----- output: {0} -----" -f $item.Name)
        Write-Host $capturedOutput
    }

    $scenarioSw.Stop()

    [pscustomobject]@{
        Scenario    = $item.Name
        Database    = $item.Db
        ExitCode    = $finalExit
        Status      = $status
        Validated   = $validated
        Flaky       = $flaky
        Artifact    = $artifact
        Kept        = $keep
        DurationSec = [math]::Round($scenarioSw.Elapsed.TotalSeconds, 2)
    }
}

# Reset state lives outside the run try/finally so the post-run finally can always reach it.
$invokeStdbScenarioDef = ${function:Invoke-StdbScenario}.ToString()
$recycleSw = [System.Diagnostics.Stopwatch]::new()
$recycleCount = 0
$parallelSw = [System.Diagnostics.Stopwatch]::new()
$rerunSw = [System.Diagnostics.Stopwatch]::new()
$results = @()
$rerunResults = @()
$envUriName = $config.Env.Uri
$envDbName = $config.Env.Db
$envClientIdName = $config.Env.ClientId
$tokenPrefix = $config.TokenPrefix

try {
    # Pre-run reset: clear any replica debt inherited from earlier/crashed runs.
    if ($effectiveRecycleEvery -gt 0) { Reset-StdbServer -Reason "pre-run: clear inherited replica debt" }

    # --- Parallel pass -------------------------------------------------------------
    $recycleNote = if ($effectiveRecycleEvery -gt 0) { (" (resetting every {0})" -f $effectiveRecycleEvery) } else { "" }
    Write-Host ("Running {0} STDB scenario(s) with up to {1} in parallel{2}..." -f $work.Count, $MaxParallel, $recycleNote)
    $parallelChunks = Split-WorkIntoChunks -items $work -size $effectiveRecycleEvery
    for ($ci = 0; $ci -lt $parallelChunks.Count; $ci++) {
        $parallelSw.Start()
        $chunkResults = @($parallelChunks[$ci]) | ForEach-Object -ThrottleLimit ([Math]::Max(1, $MaxParallel)) -Parallel {
            ${function:Invoke-StdbScenario} = $using:invokeStdbScenarioDef
            Invoke-StdbScenario -item $_ -wasmPath $using:wasmPath -ServerUri $using:ServerUri `
                -runScenarioScript $using:runScenarioScript -GodotExe $using:GodotExe `
                -keepRequested ([bool]$using:KeepDatabase) -isSingle $using:isSingle `
                -record ([bool]$using:Record) -recordFps ([int]$using:RecordFps) `
                -envUriName $using:envUriName -envDbName $using:envDbName `
                -envClientIdName $using:envClientIdName -tokenPrefix $using:tokenPrefix
        }
        $parallelSw.Stop()
        $results += $chunkResults
        if ($effectiveRecycleEvery -gt 0 -and $ci -lt $parallelChunks.Count - 1) {
            Reset-StdbServer -Reason ("parallel batch {0}/{1} done" -f ($ci + 1), $parallelChunks.Count)
        }
    }
    $results = @($results | Sort-Object Scenario)

    # --- Serial re-run pass (single attempt, DIAGNOSTIC ONLY) ----------------------
    # A scenario that failed under parallel contention is re-run ONCE, alone, on its own fresh DB.
    # This does NOT forgive it — the suite stays red (see stdb_suite_verdict.ps1). It only tells us
    # whether the failure was load-sensitive (recovered) or genuine (failed_both).
    $parallelFailedNames = @($results | Where-Object { -not $_.Validated } | Select-Object -ExpandProperty Scenario)
    if (-not $NoRerun -and $work.Count -gt 1 -and $MaxParallel -gt 1 -and $parallelFailedNames.Count -gt 0) {
        $rerunWork = @($work | Where-Object { $parallelFailedNames -contains $_.Name } | ForEach-Object {
                [pscustomobject]@{
                    Index    = $_.Index
                    Name     = $_.Name
                    FullName = $_.FullName
                    Db       = ($_.Db + "-rerun")
                    ClientId = ($_.ClientId + "-rerun")
                }
            })
        Write-Host ""
        Write-Host ("Re-running {0} parallel failure(s) serially (single attempt, diagnostic — suite stays red): {1}" -f `
                $rerunWork.Count, ($parallelFailedNames -join ", ")) -ForegroundColor Cyan
        if ($effectiveRecycleEvery -gt 0) { Reset-StdbServer -Reason "fresh server for serial re-run" }
        $rerunChunks = Split-WorkIntoChunks -items $rerunWork -size $effectiveRecycleEvery
        for ($ci = 0; $ci -lt $rerunChunks.Count; $ci++) {
            $rerunSw.Start()
            $chunkResults = @($rerunChunks[$ci]) | ForEach-Object -ThrottleLimit 1 -Parallel {
                ${function:Invoke-StdbScenario} = $using:invokeStdbScenarioDef
                Invoke-StdbScenario -item $_ -wasmPath $using:wasmPath -ServerUri $using:ServerUri `
                    -runScenarioScript $using:runScenarioScript -GodotExe $using:GodotExe `
                    -keepRequested ([bool]$using:KeepDatabase) -isSingle $using:isSingle `
                    -record ([bool]$using:Record) -recordFps ([int]$using:RecordFps) `
                    -envUriName $using:envUriName -envDbName $using:envDbName `
                    -envClientIdName $using:envClientIdName -tokenPrefix $using:tokenPrefix
            }
            $rerunSw.Stop()
            $rerunResults += $chunkResults
            if ($effectiveRecycleEvery -gt 0 -and $ci -lt $rerunChunks.Count - 1) {
                Reset-StdbServer -Reason ("rerun batch {0}/{1} done" -f ($ci + 1), $rerunChunks.Count)
            }
        }
        $rerunResults = @($rerunResults | Sort-Object Scenario)
    }
}
finally {
    # Post-run: leave the host clean (reclaim THIS run's leaked replicas) and restore the dev
    # <ModuleName> DB the resets wiped. Best-effort — never mask the original failure.
    if ($effectiveRecycleEvery -gt 0) {
        try {
            Reset-StdbServer -Reason "post-run: leave host clean"
            if ($hadModule) { spacetime publish $config.ModuleName --yes --server local --bin-path $wasmPath *> $null }
        }
        catch { Write-Host ("  warn: post-run reset/restore failed: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow }
    }
    # Sweep any of THIS run's token folders left by scenarios that crashed before their own
    # per-scenario cleanup. Scoped to $runStamp -> never touches a concurrent run's folders or the
    # dev token. Best-effort.
    Get-ChildItem ([Environment]::GetFolderPath('UserProfile')) -Directory -Filter ("{0}-test-{1}-*" -f $config.TokenPrefix, $runStamp) -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    # Contract: leave the server running.
    if (-not (Test-ServerUp)) { try { Start-StdbServer } catch { } }
}

# --- Verdict + classification ------------------------------------------------------
# STRICT policy (see stdb_suite_verdict.ps1): any scenario that did not VALIDATE in the PARALLEL
# pass fails the suite, even if its single serial re-run passed. The re-run only annotates the
# failure as load-sensitive ("recovered") vs genuine ("failed_both").
$verdict = Get-StdbSuiteVerdict -ParallelResults $results -RerunResults $rerunResults
$suiteExitCode = [int]$verdict.suite_exit_code
$suiteStatus = [string]$verdict.suite_status
$failedParallel = @($verdict.failed_parallel)
$recovered = @($verdict.recovered_on_rerun)
$failedBoth = @($verdict.failed_both)
$flakyScenarios = @($verdict.flaky_scenarios)
$validatedCount = @($results | Where-Object { $_.Validated }).Count

# --- Efficiency stats (parallel vs serial-with-reruns) -----------------------------
$parallelPhaseSec = [math]::Round($parallelSw.Elapsed.TotalSeconds, 2)
$rerunPhaseSec = [math]::Round($rerunSw.Elapsed.TotalSeconds, 2)
$totalSec = [math]::Round($parallelPhaseSec + $rerunPhaseSec, 2)
$recyclePhaseSec = [math]::Round($recycleSw.Elapsed.TotalSeconds, 2)
$sumScenarioSec = [math]::Round((($results | Measure-Object -Property DurationSec -Sum).Sum), 2)

$suiteId = Get-Date -Format "yyyyMMdd-HHmmss-fff"

# Append a per-run record to the append-only timing log (machine-specific -> under the project's
# artifacts root). The aggregator (tools/aggregate_test_timings.ps1) answers "is parallel worth
# it?". host/cores are stamped so records are never mixed across machines.
$statsDir = Join-Path $config.ArtifactsDir "stats"
$null = New-Item -ItemType Directory -Path $statsDir -Force
$statsRecord = [ordered]@{
    timestamp            = (Get-Date).ToUniversalTime().ToString("o")
    suite                = "stdb"
    suite_run_id         = $suiteId
    host                 = [System.Environment]::MachineName
    cores                = [System.Environment]::ProcessorCount
    max_parallel         = $MaxParallel
    scenario_count       = $results.Count
    parallel_phase_sec   = $parallelPhaseSec
    rerun_phase_sec      = $rerunPhaseSec
    total_sec            = $totalSec
    recycle_phase_sec    = $recyclePhaseSec
    server_recycle_every = $effectiveRecycleEvery
    server_recycle_count = $recycleCount
    sum_scenario_sec     = $sumScenarioSec
    failed_parallel      = $failedParallel
    recovered_on_rerun   = $recovered
    failed_both          = $failedBoth
    verdict_policy       = "annotate"
    suite_status         = $suiteStatus
}
($statsRecord | ConvertTo-Json -Depth 6 -Compress) | Add-Content -Path (Join-Path $statsDir "test_timings.jsonl") -Encoding utf8

# Persist a machine-readable suite record so flaky and load-sensitive runs leave a durable trail
# even when the suite exits green.
$suitePath = Join-Path $config.ArtifactsDir (Join-Path "stdb_suites" $suiteId)
$null = New-Item -ItemType Directory -Path $suitePath -Force
$rerunValidatedMap = @{}
foreach ($r in $rerunResults) { if ($null -ne $r) { $rerunValidatedMap[[string]$r.Scenario] = [bool]$r.Validated } }
$suite = [ordered]@{
    suite_run_id         = $suiteId
    suite_status         = $suiteStatus
    verdict_policy       = "annotate"
    max_parallel         = $MaxParallel
    host                 = [System.Environment]::MachineName
    cores                = [System.Environment]::ProcessorCount
    scenario_count       = $results.Count
    validated_count      = $validatedCount
    failed_count         = $failedParallel.Count
    flaky_count          = $flakyScenarios.Count
    recovered_count      = $recovered.Count
    failed_both_count    = $failedBoth.Count
    parallel_phase_sec   = $parallelPhaseSec
    rerun_phase_sec      = $rerunPhaseSec
    total_sec            = $totalSec
    recycle_phase_sec    = $recyclePhaseSec
    server_recycle_every = $effectiveRecycleEvery
    server_recycle_count = $recycleCount
    sum_scenario_sec     = $sumScenarioSec
    flaky_scenarios      = $flakyScenarios
    failed_scenarios     = $failedParallel
    recovered_on_rerun   = $recovered
    failed_both          = $failedBoth
    scenarios            = @($results | ForEach-Object {
            [ordered]@{
                scenario        = [string]$_.Scenario
                status          = [string]$_.Status
                exit_code       = [int]$_.ExitCode
                validated       = [bool]$_.Validated
                flaky           = [bool]$_.Flaky
                parallel_sec    = [double]$_.DurationSec
                database        = [string]$_.Database
                rerun_validated = $(if ($rerunValidatedMap.ContainsKey([string]$_.Scenario)) { [bool]$rerunValidatedMap[[string]$_.Scenario] } else { $null })
            }
        })
}
$suite | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $suitePath "suite.json") -Encoding utf8

Write-Host ""
Write-Host "=== STDB suite summary ===" -ForegroundColor Cyan
$results | Format-Table Scenario, Status, ExitCode, DurationSec, Database -AutoSize | Out-String | Write-Host
Write-Host ("{0}/{1} validated (max parallel {2}) -> {3}" -f $validatedCount, $results.Count, $MaxParallel, $suiteStatus.ToUpper())
Write-Host ("timing: parallel {0}s + rerun {1}s = {2}s total (sum per-scenario {3}s)" -f $parallelPhaseSec, $rerunPhaseSec, $totalSec, $sumScenarioSec)
if ($recycleCount -gt 0) {
    Write-Host ("server reset {0}x ({1}s) — every {2} scenarios (+ pre/post run), reclaiming leaked replica storage" -f $recycleCount, $recyclePhaseSec, $effectiveRecycleEvery) -ForegroundColor DarkCyan
}
if ($flakyScenarios.Count -gt 0) {
    Write-Host ("FLAKY ({0}) — assertions passed but the engine crashed on teardown under load: {1}" -f $flakyScenarios.Count, ($flakyScenarios -join ", ")) -ForegroundColor Yellow
}
if ($recovered.Count -gt 0) {
    Write-Host ("RECOVERED ON RERUN ({0}) — failed in parallel, passed serially (load-sensitive; suite STAYS red): {1}" -f $recovered.Count, ($recovered -join ", ")) -ForegroundColor Yellow
}
if ($failedBoth.Count -gt 0) {
    Write-Host ("FAILED BOTH ({0}) — failed in parallel AND on serial re-run (genuine): {1}" -f $failedBoth.Count, ($failedBoth -join ", ")) -ForegroundColor Red
}
if ($failedParallel.Count -gt 0) {
    Write-Host ("FAILED ({0}, parallel pass — suite is RED): {1}" -f $failedParallel.Count, ($failedParallel -join ", ")) -ForegroundColor Red
}

# Final orphan sweep (belt-and-suspenders): delete every "<EphemeralPrefix>-<thisRunStamp>*" DB
# except those we kept on purpose. Scoped to THIS run's stamp so it can never touch the dev DB, a
# concurrent run's in-flight DBs, or an unrelated prior run's leftovers.
$keptDbNames = @(@($results) + @($rerunResults) | Where-Object { $_ -and $_.Kept } | ForEach-Object { [string]$_.Database })
$runDbPrefix = "{0}-{1}" -f $config.EphemeralPrefix, $runStamp
$orphans = @(spacetime list --server local 2>$null |
    ForEach-Object { if ($_ -match ("(" + [regex]::Escape($runDbPrefix) + "[-\w]*)")) { $matches[1] } } |
    Where-Object { $keptDbNames -notcontains $_ } | Select-Object -Unique)
if ($orphans.Count -gt 0) {
    Write-Host ("Sweeping {0} leftover test database(s): {1}" -f $orphans.Count, ($orphans -join ", ")) -ForegroundColor DarkYellow
    foreach ($db in $orphans) { & spacetime delete $db --server local --yes *> $null }
}

exit $suiteExitCode
