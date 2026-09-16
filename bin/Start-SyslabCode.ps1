#requires -version 5.1
<#
.SYNOPSIS
    以 MWORKS.Syslab 的完整环境启动原生 VS Code。
.DESCRIPTION
    等价于 Syslab 主程序的启动方式：先在当前进程注入 Syslab 的全部环境变量
    （SYSLAB_HOME / JULIA_HOME / JULIA_DEPOT_PATH / PATH ...），再启动 Code.exe。
    这样 VS Code 里的终端、Julia 扩展、语言服务器都会直接使用 Syslab 的 Julia 运行时。
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File bin\Start-SyslabCode.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File bin\Start-SyslabCode.ps1 "D:\proj\demo.jl"
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CodeArgs
)

$ErrorActionPreference = 'Stop'
$binRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $binRoot 'syslab-env.ps1')
. (Join-Path $binRoot 'vscode-kit.ps1')

$syslabEnv = Get-SyslabEnvironment
Set-SyslabEnvironment $syslabEnv

$code = Find-VSCodeInstall
if (-not $code) {
    Write-Error '未找到 VS Code（Code.exe）。请用 install.ps1 -VSCodeExe <路径> 指定。'
    exit 1
}

Write-Host '=== 启动 VS Code（MWORKS Syslab 环境）===' -ForegroundColor Cyan
Write-Host "  Code.exe    : $($code.Exe)"
Write-Host "  SYSLAB_HOME : $($syslabEnv.Info.SyslabHome)"
Write-Host "  JULIA_HOME  : $($syslabEnv.Values.JULIA_HOME)"
Write-Host "  DEPOT       : $($syslabEnv.Values.JULIA_DEPOT_PATH)"

$argumentList = @()
if ($CodeArgs) { $argumentList = $CodeArgs }
if ($argumentList.Count -eq 0) { $argumentList = @() }

Start-Process -FilePath $code.Exe -ArgumentList $argumentList
