#requires -version 5.1
<#
.SYNOPSIS
    Self-check for the offline completion index (output of scripts\Build-CompletionIndex.ps1).
.DESCRIPTION
    Loads completion.json through extension\lib\completion.js and asserts that context
    detection, prefix search, member search (Module.symbol) and package-name search
    (after `using`) all behave as expected.

    All human-readable output comes from scripts\test-completion-index.js; this wrapper
    only locates the index file and a Node runtime (VS Code ships one via Electron).
    Exit code 0 = all checks passed, 1 = index missing / a check failed.

.PARAMETER Index
    Index path. Default: %USERPROFILE%\.syslab-vscode\completion.json

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\Test-CompletionIndex.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\Test-CompletionIndex.ps1 -Index D:\tmp\completion.json
#>
[CmdletBinding()]
param(
    [string]$Index
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$kitRoot = Split-Path -Parent $scriptRoot
. (Join-Path $kitRoot 'bin\vscode-kit.ps1')

if (-not $Index) { $Index = Join-Path $env:USERPROFILE '.syslab-vscode\completion.json' }
$Index = [System.IO.Path]::GetFullPath($Index)

if (-not (Test-Path -LiteralPath $Index)) {
    Write-Host "  [FAIL] index not found: $Index" -ForegroundColor Red
    Write-Host '         run: powershell -File scripts\Build-CompletionIndex.ps1' -ForegroundColor Yellow
    exit 1
}

$nodeScript = Join-Path $scriptRoot 'test-completion-index.js'
if (-not (Test-Path -LiteralPath $nodeScript)) {
    Write-Host "  [FAIL] missing $nodeScript" -ForegroundColor Red
    exit 1
}

$nodeExe = $null
$vscode = Find-VSCodeInstall
if ($vscode -and $vscode.Exe -and (Test-Path -LiteralPath $vscode.Exe)) {
    $nodeExe = $vscode.Exe
    $env:ELECTRON_RUN_AS_NODE = '1'
}
else {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { $nodeExe = $cmd.Source }
}
if (-not $nodeExe) {
    Write-Host '  [FAIL] no Node runtime found (install VS Code, or Node.js on PATH)' -ForegroundColor Red
    exit 1
}

& $nodeExe $nodeScript $Index
$code = $LASTEXITCODE
if ($null -eq $code) { $code = 0 }
exit $code
