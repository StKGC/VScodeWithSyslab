#requires -version 5.1
<#
.SYNOPSIS
    把桥接扩展发布到 VS Code Marketplace（上架后扩展面板可搜索，Settings Sync 可自动同步）。
.DESCRIPTION
    只发布本工具包自带的 syslab-bridge（MIT）。同元软控的 Syslab 扩展请勿上架。

    一次性准备：
      1) 安装 Node.js LTS：winget install --id OpenJS.NodeJS.LTS -e    （或 https://nodejs.org）
      2) 生成 PAT：https://dev.azure.com → User settings → Personal access tokens
         · Organization 选 All accessible organizations
         · Scopes 勾选 Marketplace → Manage
      3) 创建 publisher（名字要与 extension\package.json 的 "publisher" 完全一致）：
         https://marketplace.visualstudio.com/manage

    然后每次发版执行本脚本即可（首次会安装 vsce）。

.PARAMETER Pat
    Marketplace PAT；不传则读取环境变量 $env:VSCE_PAT。

.PARAMETER VsixPath
    要发布的 VSIX 路径；默认 vsix\<publisher>.<name>-<version>.vsix，不存在会自动打包。

.PARAMETER PackageOnly
    只打包 VSIX，不上架（用于验证 manifest / 检查文件体积）。

.PARAMETER SkipDuplicate
    版本已存在时跳过而不是报错（可安全重复执行）。

.EXAMPLE
    $env:VSCE_PAT = '<你的PAT>'
    powershell -ExecutionPolicy Bypass -File scripts\Publish-Marketplace.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\Publish-Marketplace.ps1 -PackageOnly
#>
[CmdletBinding()]
param(
    [string]$Pat,
    [string]$VsixPath,
    [switch]$PackageOnly,
    [switch]$SkipDuplicate
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$kitRoot = Split-Path -Parent $scriptRoot
. (Join-Path $kitRoot 'bin\vscode-kit.ps1')

function Write-Ok([string]$Text) { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "  [信息] $Text" -ForegroundColor Gray }
function Write-Warn2([string]$Text) { Write-Host "  [注意] $Text" -ForegroundColor Yellow }

$bridge = Get-BridgeExtensionInfo -KitRoot $kitRoot
$pkgPath = Join-Path $kitRoot 'extension\package.json'
$pkg = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Host '=== 发布桥接扩展到 VS Code Marketplace ===' -ForegroundColor Cyan
Write-Host "  扩展 ID    : $($bridge.Id)"
Write-Host "  版本       : $($bridge.Version)"
Write-Host "  名称       : $($bridge.DisplayName)"

# ---------------------------------------------------------------------------
# 1. 校验 publisher 与 PAT
# ---------------------------------------------------------------------------
if ($bridge.Publisher -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*$') {
    throw "publisher 名称不合法：$($bridge.Publisher)（只允许字母/数字/连字符，且首字符为字母或数字）"
}
Write-Ok "publisher 合法：$($bridge.Publisher)（Marketplace 中的 ID 会统一为小写 $($bridge.IdLower)）"

if (-not $pkg.PSObject.Properties['repository']) {
    Write-Warn2 'extension\package.json 里没有 repository 字段，Marketplace 页面不会显示源码链接（不影响上架）'
    Write-Warn2 '建议补上： "repository": { "type": "git", "url": "https://github.com/<你>/<仓库>.git" }'
}

if (-not $PackageOnly) {
    if (-not $Pat) { $Pat = $env:VSCE_PAT }
    if (-not $Pat) {
        Write-Host ''
        Write-Warn2 '未提供 PAT。三种做法任选其一：'
        Write-Host '    1) 本次临时提供： $env:VSCE_PAT = ''<你的PAT>''; powershell -File scripts\Publish-Marketplace.ps1'
        Write-Host '    2) 参数传入    ： powershell -File scripts\Publish-Marketplace.ps1 -Pat <你的PAT>'
        Write-Host '    3) 交互登录    ： npx --yes @vscode/vsce login ' + $bridge.Publisher
        Write-Host '    PAT 生成：https://dev.azure.com → User settings → Personal access tokens（权限 Marketplace > Manage）'
        Write-Host ''
        exit 1
    }
}

# ---------------------------------------------------------------------------
# 2. 准备 VSIX
# ---------------------------------------------------------------------------
if (-not $VsixPath) { $VsixPath = $bridge.VsixPath }
if (-not (Test-Path $VsixPath)) {
    Write-Info "未找到 $VsixPath，开始打包 ..."
    & (Join-Path $scriptRoot 'New-SyslabVsix.ps1') -SourceDir (Join-Path $kitRoot 'extension') -Force | Out-Null
}
if (-not (Test-Path $VsixPath)) { throw "打包失败：$VsixPath 不存在" }
Write-Ok ("待发布 VSIX：{0}（{1:N2} MB）" -f $VsixPath, ((Get-Item $VsixPath).Length / 1MB))

# 顺带校验 VSIX 里的 manifest 与 package.json 一致
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
$zip = [System.IO.Compression.ZipFile]::OpenRead($VsixPath)
try {
    $entry = $zip.Entries | Where-Object { $_.FullName -eq 'extension.vsixmanifest' } | Select-Object -First 1
    if ($entry) {
        $reader = New-Object System.IO.StreamReader($entry.Open())
        try { $manifestText = $reader.ReadToEnd() } finally { $reader.Dispose() }
        if ($manifestText -match [regex]::Escape("Id=`"$($bridge.Name)`"") -and
            $manifestText -match [regex]::Escape("Publisher=`"$($bridge.Publisher)`"")) {
            Write-Ok "VSIX manifest 与 package.json 一致"
        }
        else {
            Write-Warn2 'VSIX manifest 与 package.json 不一致，建议用 -Force 重新打包'
        }
    }
}
finally { $zip.Dispose() }

if ($PackageOnly) {
    Write-Host ''
    Write-Ok '仅打包完成（-PackageOnly）。上架请去掉该开关并设置 $env:VSCE_PAT。'
    exit 0
}

# ---------------------------------------------------------------------------
# 3. 检查 Node.js / vsce
# ---------------------------------------------------------------------------
$node = Get-Command node -ErrorAction SilentlyContinue
$npx = Get-Command npx -ErrorAction SilentlyContinue
if (-not $node -or -not $npx) {
    Write-Host ''
    Write-Warn2 '未检测到 Node.js / npx（上架 Marketplace 必须用 vsce，而 vsce 依赖 Node.js）。'
    Write-Host '    安装方式（任选）：'
    Write-Host '      winget install --id OpenJS.NodeJS.LTS -e'
    Write-Host '      或到 https://nodejs.org 下载 LTS 安装包'
    Write-Host '    装完后重开终端，再执行本脚本即可（会自动 npx 拉取 @vscode/vsce）。'
    exit 1
}
Write-Ok "Node.js：$(& node --version)"

# ---------------------------------------------------------------------------
# 4. 发布
# ---------------------------------------------------------------------------
$env:VSCE_PAT = $Pat
$vsceArgs = @('--yes', '@vscode/vsce', 'publish', '--packagePath', $VsixPath)
if ($pkg.PSObject.Properties['repository']) { }
else { $vsceArgs += '--allow-missing-repository' }
if ($SkipDuplicate) { $vsceArgs += '--skip-duplicate' }

Write-Host ''
Write-Info ('执行：npx ' + ($vsceArgs -join ' '))
$output = ''
try {
    $output = ((& npx @vsceArgs 2>&1) | ForEach-Object { $_.ToString() }) -join "`n"
    Write-Host $output
}
catch {
    $output = $_.Exception.Message
    Write-Host $output
}

Write-Host ''
if ($output -match 'already exists|already published|Duplicate') {
    Write-Warn2 "版本 $($bridge.Version) 已存在，如需覆盖请先在 package.json 里升版本（或用 -SkipDuplicate 忽略）"
    exit 1
}
elseif ($output -match 'ERROR|error|failed|Failed') {
    Write-Warn2 '发布失败，请检查上面的输出（常见原因：PAT 过期/权限不足、publisher 不存在或不属于该 PAT、版本号重复）'
    exit 1
}
else {
    Write-Host '=== 发布完成 ===' -ForegroundColor Green
    Write-Host "  管理页：https://marketplace.visualstudio.com/manage/publishers/$($bridge.Publisher)"
    Write-Host "  扩展页：https://marketplace.visualstudio.com/items?itemName=$($bridge.IdLower)"
    Write-Host "  安装  ：code --install-extension $($bridge.IdLower)"
    Write-Host '  建议：先手动 Install 验证一次，再通过 Settings Sync 同步到其它机器。'
}
