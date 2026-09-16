#requires -version 5.1
<#
.SYNOPSIS
    在当前控制台打开一个带完整 Syslab 环境的 Julia REPL。
.DESCRIPTION
    注入 Syslab 环境变量后启动 Syslab 自带的 julia，并预加载 TyBase / TyMath / TyPlot。
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File bin\Start-SyslabShell.ps1
#>
[CmdletBinding()]
param(
    [string]$Project,
    [string[]]$Preload = @('TyBase', 'TyMath', 'TyPlot')
)

$ErrorActionPreference = 'Stop'
$binRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $binRoot 'syslab-env.ps1')

$syslabEnv = Get-SyslabEnvironment
Set-SyslabEnvironment $syslabEnv

$julia = Join-Path ($syslabEnv.Values.JULIA_HOME -replace '/', '\') 'bin\julia.exe'
if (-not $Project) {
    $Project = Join-Path ($syslabEnv.Values.JULIA_DEPOT_PATH -replace '/', '\') 'environments\v1.10'
}

$juliaArgs = @("--project=$($Project -replace '\\', '/')", '-i', '--banner=no')
if ($Preload -and $Preload.Count -gt 0) {
    $juliaArgs += @('-e', "using $($Preload -join ', ')")
}

Write-Host "=== Syslab Julia REPL（$($syslabEnv.Info.Title)）===" -ForegroundColor Cyan
& $julia @juliaArgs
