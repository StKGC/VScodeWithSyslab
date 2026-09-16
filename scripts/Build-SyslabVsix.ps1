#requires -version 5.1
<#
.SYNOPSIS
    把 Syslab 自带的扩展打包为 VSIX，并可选择直接安装到 VS Code。
.DESCRIPTION
    VS Code 1.7x 起不再识别“手工拷贝到 %USERPROFILE%\.vscode\extensions 的扩展目录”，
    必须使用 VSIX（离线安装包）走官方安装流程，因此安装脚本采用：

        Syslab 扩展目录  ->  VSIX  ->  code --install-extension xxx.vsix --force

    生成的 VSIX 放在 <工具包>\vsix，可拷贝到其它机器离线安装。

.PARAMETER Install
    打包完成后立即用 VS Code CLI 安装。

.PARAMETER Only
    只处理指定的扩展目录名（支持通配符），例如 -Only 'tongyuan.syslab-julia-*'。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\Build-SyslabVsix.ps1 -Install
#>
[CmdletBinding()]
param(
    [string]$TongYuanExtensionsDir,
    [switch]$Install,
    [string[]]$Only
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$kitRoot = Split-Path -Parent $scriptRoot
. (Join-Path $kitRoot 'bin\syslab-env.ps1')
. (Join-Path $kitRoot 'bin\vscode-kit.ps1')

if (-not $TongYuanExtensionsDir) {
    $syslabHome = Find-SyslabHome
    if (-not $syslabHome) { throw '未找到 MWORKS.Syslab 安装目录。' }
    $info = Get-SyslabProductInfo -SyslabHome $syslabHome
    $TongYuanExtensionsDir = Join-Path ($info.TongYuanPath -replace '/', '\') '.syslab-oss\extensions'
}
if (-not (Test-Path $TongYuanExtensionsDir)) { throw "未找到 Syslab 扩展目录：$TongYuanExtensionsDir" }

$patterns = @(
    'tongyuan.syslab-julia-*',
    'tongyuan.julia-analyzer-*',
    'tongyuan.tymlang-ide-*',
    'tongyuan.app-designer-*',
    'tongyuan.mworks-syslab-copilot-*'
)
if ($Only) { $patterns = $Only }

$outputDir = Join-Path $kitRoot 'vsix'
$built = New-Object System.Collections.Generic.List[string]

Write-Host '=== 打包 Syslab 扩展为 VSIX ===' -ForegroundColor Cyan
foreach ($pattern in $patterns) {
    $source = Get-ChildItem $TongYuanExtensionsDir -Directory -Filter $pattern -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $source) {
        Write-Warning "未找到扩展：$pattern"
        continue
    }
    $vsix = & (Join-Path $scriptRoot 'New-SyslabVsix.ps1') -SourceDir $source.FullName -OutputDir $outputDir
    if ($vsix) { $built.Add([string]$vsix) }
}

Write-Host ''
Write-Host "共生成 $($built.Count) 个 VSIX，位于：$outputDir" -ForegroundColor Green

if ($Install) {
    Write-Host ''
    Write-Host '=== 使用 VS Code CLI 安装 ===' -ForegroundColor Cyan
    $vscode = Find-VSCodeInstall
    if (-not $vscode) { throw '未找到 VS Code，无法自动安装。' }
    $codeCmd = $vscode.CodeCmd
    if (-not $codeCmd) { throw "未找到 code.cmd，请手动安装：$outputDir\*.vsix" }

    foreach ($vsix in $built) {
        Write-Host "  安装 $([System.IO.Path]::GetFileName($vsix)) ..."
        $output = & $codeCmd --install-extension $vsix --force 2>&1 | Out-String
        if ($output -match 'successfully installed') {
            Write-Host "    [OK]" -ForegroundColor Green
        }
        else {
            Write-Host "    [失败] $($output.Trim())" -ForegroundColor Red
        }
    }
}

# 输出 VSIX 路径列表（供 install.ps1 等调用方使用）
$built
