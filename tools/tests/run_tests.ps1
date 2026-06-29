# Runs every engine-free (no Godot, no SpacetimeDB) unit check under tools/tests/ and fails if
# any fails. These pin the kit's pure logic — the STDB suite verdict (incl. the anti-masking
# "recovered-on-rerun still exits 1" guard) and the timing aggregator math — so CI can verify
# them in milliseconds without a display or a server.
#
#   ./tools/tests/run_tests.ps1
param()

$ErrorActionPreference = "Stop"
$tests = @(
    Get-ChildItem -Path $PSScriptRoot -Filter "test_*.ps1" -File | Sort-Object Name
)
if ($tests.Count -eq 0) { throw "No test_*.ps1 files found under $PSScriptRoot." }

$failed = @()
foreach ($test in $tests) {
    Write-Host ("=== {0} ===" -f $test.Name) -ForegroundColor Cyan
    & pwsh -NoProfile -File $test.FullName
    if ($LASTEXITCODE -ne 0) { $failed += $test.Name }
    Write-Host ""
}

if ($failed.Count -gt 0) {
    Write-Host ("UNIT CHECKS FAILED ({0}/{1}): {2}" -f $failed.Count, $tests.Count, ($failed -join ", ")) -ForegroundColor Red
    exit 1
}
Write-Host ("ALL UNIT CHECKS OK ({0}/{0})" -f $tests.Count) -ForegroundColor Green
exit 0
