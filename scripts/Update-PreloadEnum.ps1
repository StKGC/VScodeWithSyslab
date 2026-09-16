#requires -version 5.1
<#
.SYNOPSIS
    按当前 Syslab 环境刷新「预加载包」设置页的下拉候选（enum）。
.DESCRIPTION
    设置页里 `syslab.preloadPackages` 的下拉候选写在**已安装扩展**的 package.json 里。
    本脚本把候选替换成当前 Syslab 默认环境真实可用的包（[deps] + 常用标准库，本机约 155 个），
    所以在设置页选中任何一项都保证能 `using` 成功。

    什么时候需要重跑：
      · 用 `Pkg.add` 新装了包，想让下拉里出现它；
      · 重新安装/升级过桥接扩展（安装包里的候选是精简版）。

    install.ps1 在安装桥接扩展后会自动调用本脚本，一般不需要手动执行。

.PARAMETER DryRun
    只显示将要写入的候选数量，不修改文件。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\Update-PreloadEnum.ps1
#>
[CmdletBinding()]
param(
    [string]$ExtensionsDir,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$kitRoot = Split-Path -Parent $scriptRoot
. (Join-Path $kitRoot 'bin\syslab-env.ps1')
. (Join-Path $kitRoot 'bin\vscode-kit.ps1')

function Write-Ok([string]$Text) { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "  [信息] $Text" -ForegroundColor Gray }
function Write-Warn2([string]$Text) { Write-Host "  [注意] $Text" -ForegroundColor Yellow }

function Get-PreloadEnumCount {
    param([string]$PackageJsonPath)
    try {
        $pkg = Get-Content $PackageJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $items = $pkg.contributes.configuration.properties.'syslab.preloadPackages'.items
        if ($items -and $items.enum) { return @($items.enum).Count }
    }
    catch { }
    return -1
}

$bridge = Get-BridgeExtensionInfo -KitRoot $kitRoot
if (-not $ExtensionsDir) { $ExtensionsDir = Join-Path $env:USERPROFILE '.vscode\extensions' }

$installed = Get-ChildItem $ExtensionsDir -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq $bridge.IdLower -or $_.Name -like "$($bridge.IdLower)-*" } |
    Sort-Object Name -Descending | Select-Object -First 1
if (-not $installed) {
    Write-Warn2 "未找到已安装的桥接扩展（$($bridge.IdLower)），请先运行 install.ps1"
    exit 1
}

$syslabEnv = Get-SyslabEnvironment
$info = $syslabEnv.Info
$juliaMatch = [regex]::Match([string]$info.JuliaVersion, '(\d+)\.(\d+)')
if (-not $juliaMatch.Success) { Write-Warn2 "无法从 $($info.JuliaVersion) 解析 Julia 主次版本"; exit 1 }
$envDir = Join-Path ($syslabEnv.Values.JULIA_DEPOT_PATH -replace '/', '\') `
    ("environments\v" + $juliaMatch.Groups[1].Value + "." + $juliaMatch.Groups[2].Value)
$projectPath = Join-Path $envDir 'Project.toml'
$manifestPath = Join-Path $envDir 'Manifest.toml'

if (-not (Test-Path $projectPath)) { Write-Warn2 "未找到环境文件：$projectPath"; exit 1 }

$vscode = Find-VSCodeInstall
if (-not $vscode) { Write-Warn2 '未找到 VS Code，无法调用 Node 运行时（脚本需要 Node 来安全改写 JSON）'; exit 1 }

$nodeScript = Join-Path $scriptRoot 'update-preload-enum.js'
$pkgJson = Join-Path $installed.FullName 'package.json'
$countBefore = Get-PreloadEnumCount -PackageJsonPath $pkgJson
Write-Info "扩展清单 : $pkgJson"
Write-Info "环境文件 : $projectPath"
Write-Info "候选数量 : 修改前 $countBefore"

$nodeArgs = @($nodeScript, $pkgJson, $projectPath, $manifestPath)
if ($DryRun) { $nodeArgs += '--dry-run' }

$env:ELECTRON_RUN_AS_NODE = '1'
try { & $vscode.Exe @nodeArgs | Out-Null } catch { Write-Warn2 "调用 Node 失败：$($_.Exception.Message)" }
Start-Sleep -Milliseconds 500

$countAfter = Get-PreloadEnumCount -PackageJsonPath $pkgJson
if ($DryRun) {
    Write-Ok "-DryRun：未写入。当前候选 $countAfter 个"
    exit 0
}
if ($countAfter -gt $countBefore -and $countAfter -gt 0) {
    Write-Ok "下拉候选已刷新：$countBefore -> $countAfter 个（设置页刷新/重载窗口后可见）"
}
elseif ($countAfter -eq $countBefore -and $countAfter -gt 0) {
    Write-Info "候选数量未变化（$countAfter 个），可能是环境读取失败或本来就已是最新"
}
else {
    Write-Warn2 "刷新失败：候选数量 $countAfter（原 $countBefore）"
    exit 1
}
