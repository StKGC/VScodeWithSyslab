#requires -version 5.1
<#
.SYNOPSIS
    卸载 install.ps1 写入到 VS Code 的 Syslab 集成。
.DESCRIPTION
    1. 删除 VS Code 用户扩展目录中的 Syslab 扩展（StKGC.* 与旧前缀 tongyuan.*）与桥接扩展；
    2. 删除 %USERPROFILE%\.syslab-vscode 环境文件；
    3. 清理 settings.json 中由 install.ps1 写入的键（或用 -RestoreSettings 直接还原备份）。

.PARAMETER RestoreSettings
    用 settings.json.syslab-bak 覆盖当前 settings.json（install.ps1 首次写入前的备份）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File uninstall.ps1
#>
[CmdletBinding()]
param(
    [switch]$RestoreSettings
)

$ErrorActionPreference = 'Stop'
$KitRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $KitRoot 'bin\vscode-kit.ps1')

$ExtensionsDir = Join-Path $env:USERPROFILE '.vscode\extensions'
$UserSettingsDir = Join-Path $env:APPDATA 'Code\User'
$settingsPath = Join-Path $UserSettingsDir 'settings.json'
$backupPath = "$settingsPath.syslab-bak"

Write-Host '=== 卸载 MWORKS Syslab × VS Code 集成 ===' -ForegroundColor Cyan

# 1. 扩展
$bridge = Get-BridgeExtensionInfo -KitRoot $KitRoot
$syslabNames = @('syslab-julia', 'tymlang-ide', 'julia-analyzer', 'app-designer', 'mworks-syslab-copilot')
$targets = @($syslabNames | ForEach-Object { "$($bridge.Publisher).$_".ToLower() })
$targets += @($syslabNames | ForEach-Object { "tongyuan.$_" })   # 旧前缀
$targets += @($bridge.IdLower, 'stkgc.syslab-bridge', 'syslab-community.syslab-bridge')
foreach ($id in $targets) {
    Get-ChildItem $ExtensionsDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $id -or $_.Name -like "$id-*" } |
        ForEach-Object {
            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  已删除扩展 $($_.Name)"
        }
}

# 2. 环境文件
$envDir = Join-Path $env:USERPROFILE '.syslab-vscode'
if (Test-Path $envDir) {
    Remove-Item $envDir -Recurse -Force
    Write-Host "  已删除 $envDir"
}

# 3. 设置
if (Test-Path $settingsPath) {
    if ($RestoreSettings -and (Test-Path $backupPath)) {
        Copy-Item $backupPath $settingsPath -Force
        Remove-Item $backupPath -Force
        Write-Host "  已还原 settings.json（备份 $backupPath）"
    }
    else {
        $settings = Read-JsoncFile -Path $settingsPath
        foreach ($key in 'julia.executablePath', 'julia.syslab.logPath', 'julia.syslab.simulationResultPath',
            'julia.syslab.preloadPkgs', 'julia.syslab.repl.defaultStart', 'syslab.envFile',
            'syslab.juliaExecutable', 'syslab.projectPath', 'syslab.syslabExecutable',
            'terminal.integrated.env.windows') {
            Remove-SettingDeep $settings $key
        }
        if ($settings.ContainsKey('terminal.integrated.profiles.windows') -and
            $settings['terminal.integrated.profiles.windows'].ContainsKey('Syslab Julia')) {
            $settings['terminal.integrated.profiles.windows'].Remove('Syslab Julia')
        }
        $settings | ConvertTo-Json -Depth 20 | Set-Content -Path $settingsPath -Encoding UTF8
        Write-Host '  已清理 settings.json 中的 Syslab 相关键'
    }
}

Write-Host ''
Write-Host '卸载完成。' -ForegroundColor Green
