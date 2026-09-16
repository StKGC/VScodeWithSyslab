#requires -version 5.1
<#
.SYNOPSIS
    生成 Julia 代码补全索引（供 VS Code 桥接扩展离线提供自动补全）。
.DESCRIPTION
    纯 VS Code 里没有可用的 Julia 语言服务（Syslab 的语言服务器依赖的包不在 depot 里），
    因此本工具包自带一套补全：先用 Syslab 自带的 Julia 把「常用包/预加载包」的导出符号
    （名字、种类、一行文档）导出成 JSON 缓存，扩展再据此给出补全。

    产出：~/.syslab-vscode/completion.json

.PARAMETER Packages
    要索引的包（逗号分隔）。默认取设置里的预加载包（julia.syslab.preloadPkgs / syslab.preloadPackages），
    都没有时用 TyBase,TyMath,TyPlot。

.PARAMETER ExtraPackages
    额外追加索引的包，例如 TyStatistics,TyFileIO,DataFrames,LinearAlgebra。

.PARAMETER NoDocs
    不抓取一行文档（索引更小、生成更快）。

.PARAMETER Output
    输出路径，默认 %USERPROFILE%\.syslab-vscode\completion.json。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\Build-CompletionIndex.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\Build-CompletionIndex.ps1 -ExtraPackages TyStatistics,TyFileIO,DataFrames
#>
[CmdletBinding()]
param(
    [string[]]$Packages,
    [string[]]$ExtraPackages,
    [switch]$NoDocs,
    [string]$Output
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$kitRoot = Split-Path -Parent $scriptRoot
. (Join-Path $kitRoot 'bin\syslab-env.ps1')

function Write-Ok([string]$Text) { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "  [信息] $Text" -ForegroundColor Gray }
function Write-Warn2([string]$Text) { Write-Host "  [注意] $Text" -ForegroundColor Yellow }

$syslabEnv = Get-SyslabEnvironment
Set-SyslabEnvironment $syslabEnv   # 必须注入：否则 julia 用默认 depot，找不到 TyBase/TyMath/TyPlot
$info = $syslabEnv.Info
$julia = Join-Path ($syslabEnv.Values.JULIA_HOME -replace '/', '\') 'bin\julia.exe'
if (-not (Test-Path $julia)) { throw "未找到 julia.exe：$julia" }

$match = [regex]::Match([string]$info.JuliaVersion, '(\d+)\.(\d+)')
$projectDir = Join-Path ($syslabEnv.Values.JULIA_DEPOT_PATH -replace '/', '\') `
    ("environments\v" + $match.Groups[1].Value + "." + $match.Groups[2].Value)

if (-not $Output) {
    $envDir = Join-Path $env:USERPROFILE '.syslab-vscode'
    if (-not (Test-Path $envDir)) { New-Item -ItemType Directory -Path $envDir -Force | Out-Null }
    $Output = Join-Path $envDir 'completion.json'
}

# 1) 包列表：显式参数 > 设置里的预加载包 > 默认三个
$list = New-Object System.Collections.Generic.List[string]
if ($Packages) {
    foreach ($p in $Packages) { foreach ($one in ([string]$p -split ',')) { if ($one.Trim()) { $list.Add($one.Trim()) } } }
}
if ($list.Count -eq 0) {
    $settingsPath = Join-Path $env:APPDATA 'Code\User\settings.json'
    if (Test-Path $settingsPath) {
        try {
            $settings = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $fromBridge = $settings.syslab.preloadPackages
            $fromJulia = $settings.julia.syslab.preloadPkgs
            $chosen = if ($fromBridge) { $fromBridge } elseif ($fromJulia) { $fromJulia } else { $null }
            if ($chosen) { foreach ($p in $chosen) { if ($p) { $list.Add([string]$p) } } }
        }
        catch { Write-Warn2 "读取设置失败，使用默认包列表：$($_.Exception.Message)" }
    }
}
if ($list.Count -eq 0) { @('TyBase', 'TyMath', 'TyPlot') | ForEach-Object { $list.Add($_) } }
if ($ExtraPackages) {
    foreach ($p in $ExtraPackages) { foreach ($one in ([string]$p -split ',')) { if ($one.Trim()) { $list.Add($one.Trim()) } } }
}
$packageList = ($list | Select-Object -Unique) -join ','

Write-Info "Julia    : $julia"
Write-Info "环境     : $projectDir"
Write-Info "索引包   : $packageList"
Write-Info "输出     : $Output"
Write-Host '  （首次会加载这些包，可能需要几十秒；之后索引可离线复用）' -ForegroundColor DarkGray

$scriptPath = Join-Path $scriptRoot 'build-completion-index.jl'
$juliaArgs = @("--project=$($projectDir -replace '\\', '/')", $scriptPath, $Output, $packageList)
if ($NoDocs) { $juliaArgs += '--no-docs' }

$sw = [System.Diagnostics.Stopwatch]::StartNew()
& $julia @juliaArgs
$exitCode = $LASTEXITCODE
$sw.Stop()

if ($exitCode -ne 0 -or -not (Test-Path $Output)) {
    Write-Warn2 "生成失败（退出码 $exitCode）"
    exit 1
}
$sizeKb = [Math]::Round((Get-Item $Output).Length / 1KB, 1)
Write-Ok ("索引已生成：{0}（{1} KB，耗时 {2:N1} 秒）" -f $Output, $sizeKb, $sw.Elapsed.TotalSeconds)
