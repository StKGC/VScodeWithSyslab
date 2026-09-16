#requires -version 5.1
<#
.SYNOPSIS
    打包「可上云」的扩展发布包（VSIX + manifest.json + SHA256SUMS），用于多机/多平台同步安装。
.DESCRIPTION
    产物目录（默认 <工具包>\release）：

        release\
        ├─ manifest.json                 发布清单（扩展 ID/版本/文件/校验和/适用平台）
        ├─ SHA256SUMS.txt                校验和清单（sha256sum -c 可直接用）
        ├─ TongYuan.syslab-julia-26.1.0.vsix
        ├─ TongYuan.julia-analyzer-26.4.0.vsix
        ├─ TongYuan.tymlang-ide-26.1.0.vsix
        ├─ TongYuan.app-designer-26.1.0.vsix
        └─ syslab-community.syslab-bridge-1.0.0.vsix

    把整个 release 目录丢到 GitHub Release / 对象存储 / 内网 HTTP / 网盘即可，
    其它机器用 scripts\Install-ExtensionPack.ps1（Windows）或 install.sh（Linux/macOS）拉取安装。

.PARAMETER ReleaseDir
    发布包输出目录，默认 <工具包>\release。

.PARAMETER PackVersion
    发布包版本号，默认按日期生成（如 2026.0916）。

.PARAMETER IncludeCopilot
    一并打包 MWORKS Copilot 扩展（默认不含，需 Syslab 账号/服务器）。

.PARAMETER Zip
    额外打成一个 zip（便于上传网盘/Release 附件）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\Pack-ExtensionRelease.ps1 -Zip
#>
[CmdletBinding()]
param(
    [string]$ReleaseDir,
    [string]$PackVersion,
    [switch]$IncludeCopilot,
    [switch]$Zip
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$kitRoot = Split-Path -Parent $scriptRoot
. (Join-Path $kitRoot 'bin\syslab-env.ps1')
. (Join-Path $kitRoot 'bin\vscode-kit.ps1')

$bridgeInfo = Get-BridgeExtensionInfo -KitRoot $kitRoot

if (-not $ReleaseDir) { $ReleaseDir = Join-Path $kitRoot 'release' }
if (-not $PackVersion) { $PackVersion = (Get-Date).ToString('yyyy.MMdd') }
if (Test-Path $ReleaseDir) { Remove-Item $ReleaseDir -Recurse -Force }
New-Item -ItemType Directory -Path $ReleaseDir -Force | Out-Null

$syslabEnv = Get-SyslabEnvironment
$info = $syslabEnv.Info
$vscode = Find-VSCodeInstall

Write-Host '=== 打包扩展发布包 ===' -ForegroundColor Cyan
Write-Host "  Syslab : $($info.Title) $($info.SyslabVersion)"
Write-Host "  Julia  : $($info.JuliaVersion)"
Write-Host "  输出   : $ReleaseDir"
Write-Host "  版本   : $PackVersion"

# ---------------------------------------------------------------------------
# 1. 生成 VSIX（Syslab 自带扩展 + 桥接扩展）
# ---------------------------------------------------------------------------
$tongYuanExtDir = Join-Path ($info.TongYuanPath -replace '/', '\') '.syslab-oss\extensions'
$patterns = @('tongyuan.syslab-julia-*', 'tongyuan.julia-analyzer-*', 'tongyuan.tymlang-ide-*', 'tongyuan.app-designer-*')
if ($IncludeCopilot) { $patterns += 'tongyuan.mworks-syslab-copilot-*' }

$vsixFiles = @()
if (Test-Path $tongYuanExtDir) {
    $vsixFiles += & (Join-Path $scriptRoot 'Build-SyslabVsix.ps1') -TongYuanExtensionsDir $tongYuanExtDir -Only $patterns
}
else {
    Write-Warning "未找到 Syslab 扩展目录：$tongYuanExtDir"
}
$vsixFiles += & (Join-Path $scriptRoot 'New-SyslabVsix.ps1') -SourceDir (Join-Path $kitRoot 'extension')
$vsixFiles = $vsixFiles | Where-Object { $_ -and (Test-Path $_) }

# ---------------------------------------------------------------------------
# 2. 复制到发布目录 + 计算校验和
# ---------------------------------------------------------------------------
$extensions = @()
foreach ($vsix in $vsixFiles) {
    $name = [System.IO.Path]::GetFileName($vsix)
    $target = Join-Path $ReleaseDir $name
    Copy-Item $vsix $target -Force

    # 从扩展目录名解析 ID/版本：<publisher>.<name>-<version>.vsix
    $base = [System.IO.Path]::GetFileNameWithoutExtension($name)
    $idx = $base.LastIndexOf('-')
    $id = if ($idx -gt 0) { $base.Substring(0, $idx) } else { $base }
    $version = if ($idx -gt 0) { $base.Substring($idx + 1) } else { '' }

    $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLower()
    $size = (Get-Item $target).Length
    $extensions += [ordered]@{
        id      = $id
        version = $version
        file    = $name
        sha256  = $hash
        size    = $size
        note    = if ($bridgeInfo -and $id -eq $bridgeInfo.IdLower) { "本工具包自带桥接扩展（$($bridgeInfo.Publisher) / MIT）" } else { '来自本机 MWORKS.Syslab 安装，请遵守同元软控许可，仅限自有环境分发' }
    }
    Write-Host ("  [OK] {0}  {1:N1} MB  {2}" -f $name, ($size / 1MB), $hash.Substring(0, 16))
}

# ---------------------------------------------------------------------------
# 3. manifest.json / SHA256SUMS.txt
# ---------------------------------------------------------------------------
$manifest = [ordered]@{
    packName     = 'syslab-vscode-pack'
    packVersion  = $PackVersion
    generatedAt  = (Get-Date).ToString('s')
    platform     = 'universal'   # 这些扩展均为纯 JS/自带多平台服务，无平台专属二进制
    source       = [ordered]@{
        syslabTitle   = $info.Title
        syslabVersion = $info.SyslabVersion
        juliaVersion  = $info.JuliaVersion
        vscodeVersion = if ($vscode) { $vscode.Version } else { '' }
    }
    extensions   = $extensions
    installers   = [ordered]@{
        windows = 'install.ps1  /  scripts\Install-ExtensionPack.ps1 -Source <本目录 URL>'
        posix   = 'install.sh  --base-url <本目录 URL>'
    }
    requirements = @(
        '目标机器需已安装 MWORKS.Syslab（提供 Julia 运行时与 TyBase/TyMath/TyPlot 等包）',
        'Windows 上用 install.ps1 写入环境变量；Linux/macOS 上用 install.sh',
        'Syslab 自带的扩展版权归同元软控所有，请勿公开发布到 VS Code Marketplace'
    )
}
$manifestPath = Join-Path $ReleaseDir 'manifest.json'
[System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))

$sumLines = foreach ($ext in $extensions) { "$($ext.sha256)  $($ext.file)" }
$sumPath = Join-Path $ReleaseDir 'SHA256SUMS.txt'
[System.IO.File]::WriteAllLines($sumPath, $sumLines, [System.Text.UTF8Encoding]::new($false))

# ---------------------------------------------------------------------------
# 4. 可选：打成 zip
# ---------------------------------------------------------------------------
if ($Zip) {
    $zipPath = Join-Path $kitRoot ("syslab-vscode-pack-$PackVersion.zip")
    New-ZipArchiveFromDirectory -SourceDir $ReleaseDir -ZipPath $zipPath | Out-Null
    Write-Host ("  [OK] {0}  {1:N1} MB" -f [System.IO.Path]::GetFileName($zipPath), ((Get-Item $zipPath).Length / 1MB))
}

# ---------------------------------------------------------------------------
# 5. 上传提示
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 发布包已生成 ===' -ForegroundColor Green
Write-Host "  目录：$ReleaseDir"
Write-Host "  文件：$($extensions.Count) 个 VSIX + manifest.json + SHA256SUMS.txt"
Write-Host ''
Write-Host '  上传到云端（任选其一，详见 cloud\PUBLISH.md）：' -ForegroundColor White
Write-Host '    1) GitHub Release ：把 release 目录整体作为 Release 附件上传'
Write-Host '    2) 对象存储/静态站点：上传 release 目录，得到形如 https://xxx/ 的基地址'
Write-Host '    3) 内网 HTTP / 网盘共享：拷贝 release 目录，其它机器用 Install-ExtensionPack.ps1 / install.sh 拉取'
Write-Host ''
Write-Host '  其它机器安装：' -ForegroundColor White
Write-Host '    Windows : powershell -File scripts\Install-ExtensionPack.ps1 -Source <基地址或本地目录>'
Write-Host '    Linux   : ./install.sh --base-url <基地址>   （macOS 同）'
Write-Host ''
