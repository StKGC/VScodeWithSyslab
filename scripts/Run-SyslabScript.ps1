#requires -version 5.1
<#
.SYNOPSIS
    用 MWORKS Syslab 自带的 Julia 运行 .jl 脚本（命令行方式）。
.DESCRIPTION
    等价于 VS Code 中 “Syslab: 运行当前脚本”，便于批处理/CI 场景。

.PARAMETER Path
    要运行的 .jl 脚本路径。

.PARAMETER ScriptArgs
    传给脚本的参数。

.PARAMETER Project
    Julia 环境路径，默认 Syslab 默认环境（JULIA_DEPOT_PATH\environments\v1.10）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\Run-SyslabScript.ps1 samples\hello_syslab.jl
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Path,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$ScriptArgs,
    [string]$Project
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$kitRoot = Split-Path -Parent $scriptRoot
. (Join-Path $kitRoot 'bin\syslab-env.ps1')

$syslabEnv = Get-SyslabEnvironment
Set-SyslabEnvironment $syslabEnv

$julia = Join-Path ($syslabEnv.Values.JULIA_HOME -replace '/', '\') 'bin\julia.exe'
if (-not (Test-Path $julia)) { throw "未找到 julia.exe：$julia" }

if (-not $Project) {
    $Project = Join-Path ($syslabEnv.Values.JULIA_DEPOT_PATH -replace '/', '\') 'environments\v1.10'
}
if (-not (Test-Path $Path)) { throw "脚本不存在：$Path" }
$fullPath = (Resolve-Path $Path).Path

$juliaArgs = @("--project=$($Project -replace '\\', '/')", $fullPath)
if ($ScriptArgs) { $juliaArgs += $ScriptArgs }

Write-Host "=== Syslab 运行：$fullPath" -ForegroundColor Cyan
Write-Host "    project = $Project"
& $julia @juliaArgs
exit $LASTEXITCODE
