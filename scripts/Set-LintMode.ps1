#requires -version 5.1
<#
.SYNOPSIS
    一键调整 Julia 静态检查（linter）的严格程度，收敛“引用缺失 / MissingRef”这类噪音。
.DESCRIPTION
    纯 VS Code 里有两套静态检查同时在工作：

      · StKGC.syslab-julia  —— Syslab Julia 扩展自带 linter（julia-vscode 血统）
                               未定义引用就是它报的，诊断码形如 MissingRef
                               由 julia.lint.* 控制
      · StKGC.julia-analyzer —— 独立分析器（julia-analyzer 二进制）
                               报“未定义的全局变量 / 类型不稳定”等，由 julia-analyzer.* 控制

    本脚本按档位写成对的设置（写入 VS Code 用户设置，改前自动备份）：

      quiet    —— 基本不打扰：关掉两套 linter 的“未定义引用/类型”检查，只保留语法级提示
      balanced —— 默认推荐：保留常规 lint，关掉误报较多的“类型不稳定 / 类型检查”
      strict   —— 全开（missingrefs = all + 类型检查）

    注意：如果某个符号**确实不存在**（例如 TyPlot 里只有 `figure()`，没有 `figureJulia()`），
    正确做法是改代码，而不是关检查；本脚本只用于处理“运行时能解析、静态检查看不到”的噪音。

.PARAMETER Mode
    quiet / balanced / strict，默认 balanced。

.PARAMETER Show
    只显示当前相关设置，不做修改。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\Set-LintMode.ps1 -Show
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\Set-LintMode.ps1 -Mode quiet
#>
[CmdletBinding()]
param(
    [ValidateSet('quiet', 'balanced', 'strict')]
    [string]$Mode = 'balanced',
    [string]$UserSettingsDir,
    [switch]$Show
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$kitRoot = Split-Path -Parent $scriptRoot
. (Join-Path $kitRoot 'bin\vscode-kit.ps1')

if (-not $UserSettingsDir) { $UserSettingsDir = Join-Path $env:APPDATA 'Code\User' }
$settingsPath = Join-Path $UserSettingsDir 'settings.json'
$settings = Read-JsoncFile -Path $settingsPath

function Get-SettingValue {
    param([hashtable]$Table, [string]$Path)
    $parts = $Path -split '\.'
    $current = $Table
    foreach ($key in $parts) {
        if (-not ($current -is [hashtable]) -or -not $current.ContainsKey($key)) { return $null }
        $current = $current[$key]
    }
    return $current
}

$keys = @(
    'julia.lint.run', 'julia.lint.missingrefs', 'julia.lint.call', 'julia.lint.iter',
    'julia-analyzer.lint.enable', 'julia-analyzer.lint.unstableType.enable', 'julia-analyzer.typechecking.enable'
)

Write-Host '=== 当前 Julia 静态检查设置 ===' -ForegroundColor Cyan
foreach ($key in $keys) {
    $value = Get-SettingValue -Table $settings -Path $key
    $shown = if ($null -eq $value) { '（未设置，用扩展默认值）' } else { [string]$value }
    Write-Host ("  {0,-42} {1}" -f $key, $shown)
}

if ($Show) { return }

# 两套 linter 的档位矩阵
$presets = @{
    quiet = @{
        'julia.lint.run'                          = $false
        'julia.lint.missingrefs'                  = 'none'
        'julia.lint.call'                         = $false
        'julia.lint.iter'                         = $false
        'julia-analyzer.lint.enable'              = $false
        'julia-analyzer.lint.unstableType.enable' = $false
        'julia-analyzer.typechecking.enable'      = $false
    }
    balanced = @{
        'julia.lint.run'                          = $true
        'julia.lint.missingrefs'                  = 'package functions'
        'julia.lint.call'                         = $true
        'julia.lint.iter'                         = $true
        'julia-analyzer.lint.enable'              = $true
        'julia-analyzer.lint.unstableType.enable' = $false
        'julia-analyzer.typechecking.enable'      = $false
    }
    strict = @{
        'julia.lint.run'                          = $true
        'julia.lint.missingrefs'                  = 'all'
        'julia.lint.call'                         = $true
        'julia.lint.iter'                         = $true
        'julia-analyzer.lint.enable'              = $true
        'julia-analyzer.lint.unstableType.enable' = $true
        'julia-analyzer.typechecking.enable'      = $true
    }
}

$backupPath = "$settingsPath.syslab-bak"
if ((Test-Path $settingsPath) -and -not (Test-Path $backupPath)) {
    Copy-Item $settingsPath $backupPath -Force
    Write-Host "  已备份原设置：$backupPath" -ForegroundColor DarkGray
}

foreach ($key in $presets[$Mode].Keys) {
    Set-SettingDeep $settings $key $presets[$Mode][$key]
}

if (-not (Test-Path $UserSettingsDir)) { New-Item -ItemType Directory -Path $UserSettingsDir -Force | Out-Null }
$settings | ConvertTo-Json -Depth 20 | Set-Content -Path $settingsPath -Encoding UTF8

Write-Host ''
Write-Host "已应用档位：$Mode" -ForegroundColor Green
foreach ($key in $keys) {
    Write-Host ("  {0,-42} {1}" -f $key, [string](Get-SettingValue -Table $settings -Path $key))
}
Write-Host ''
Write-Host '  生效方式：VS Code 里执行 Developer: Reload Window（已有的诊断会在重新分析后消失）。' -ForegroundColor Yellow
Write-Host '  提示：若是某个符号确实不存在（例如 TyPlot 只有 figure()，没有 figureJulia()），请改代码；' -ForegroundColor Yellow
Write-Host '        本档位只用于消除“运行时能解析、静态检查看不到”的误报。' -ForegroundColor Yellow
