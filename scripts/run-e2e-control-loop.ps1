# scripts/run-e2e-control-loop.ps1
param(
    [string]$GitRepoUrl,
    [string]$GitBranch = 'main',
    [string]$PrimaryProfile = 'dev',
    [int]$MinikubeCpus = 4,
    [int]$MinikubeMemoryMb = 6144,
    [switch]$RecreateProfiles
)

$ErrorActionPreference = 'Stop'

# 1. Load shared functions and initialize state
. $PSScriptRoot\e2e\common.ps1

# 2. Resolve Git Repo
if (-not $GitRepoUrl) {
    $gitOrigin = git config --get remote.origin.url 2>$null
    if ($LASTEXITCODE -eq 0 -and $gitOrigin) { $GitRepoUrl = $gitOrigin.Trim() }
    else { throw 'Provide -GitRepoUrl or configure git remote.origin.url.' }
}
Write-Host "Using Git repository : $GitRepoUrl | Branch: $GitBranch"

$profiles = @('dev', 'staging', 'prod')
$context = $PrimaryProfile

# 3. Execute Modular Test Suites (Dot-sourced to share $script:LayerResults)
. $PSScriptRoot\e2e\01-Bootstrap.ps1
. $PSScriptRoot\e2e\02-Deploy-Controllers.ps1
. $PSScriptRoot\e2e\03-Test-Security.ps1
. $PSScriptRoot\e2e\04-Test-Observability.ps1
. $PSScriptRoot\e2e\05-Test-Reaction.ps1
. $PSScriptRoot\e2e\06-Test-Tracing.ps1  
. $PSScriptRoot\e2e\07-Test-Cilium.ps1   # <-- ADD THIS LINE

# 4. Final Summary
Write-Host "`n=============================================="
Write-Host "Control-Loop Layer Results"
Write-Host "=============================================="

$overallPass = $true
foreach ($kv in $script:LayerResults.GetEnumerator()) {
    $status = if ($kv.Value) { 'PASS' } else { 'FAIL' }
    $color  = if ($kv.Value) { 'Green' } else { 'Red' }
    if (-not $kv.Value) { $overallPass = $false }
    Write-Host ("{0,-42} : {1}" -f $kv.Key, $status) -ForegroundColor $color
}

Write-Host "=============================================="
if ($overallPass) { Write-Host 'Overall result: PASS' -ForegroundColor Green; exit 0 }
else { Write-Host 'Overall result: FAIL' -ForegroundColor Red; exit 1 }