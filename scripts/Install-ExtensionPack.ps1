#requires -version 5.1
<#
.SYNOPSIS
    从云端（或本地）扩展发布包安装 Syslab × VS Code 扩展，实现多机同步。
.DESCRIPTION
    配合 scripts\Pack-ExtensionRelease.ps1 生成的发布包使用。支持四种来源：

        1) 发布目录的基地址（HTTP/HTTPS）    -Source https://example.com/syslab-pack/
        2) manifest.json 的直链              -Source https://example.com/syslab-pack/manifest.json
        3) 发布包 zip                        -Source https://example.com/syslab-pack.zip
        4) 本地目录 / 本地 zip / 单个 .vsix  -Source D:\share\syslab-pack

    安装流程：下载（或读取）→ 按 manifest.json 校验 SHA256 → code --install-extension --force
              → 可选调用 install.ps1 写入 Syslab 环境变量与 VS Code 设置。

.PARAMETER Source
    发布包来源（基地址 / manifest.json / zip / 本地目录 / 单个 vsix）。

.PARAMETER Token
    私有仓库（如 GitHub 私有 Release）访问令牌，会以 Bearer 形式加到请求头。

.PARAMETER OnlyBridge
    只安装本工具包的桥接扩展（StKGC.vscodewithsyslab），不安装同元软控的扩展。

.PARAMETER SkipEnv
    只装扩展，不写入环境变量/设置（之后可手动运行 install.ps1）。

.PARAMETER SkipVerify
    跳过 SHA256 校验（不建议）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\Install-ExtensionPack.ps1 -Source https://example.com/syslab-pack/
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\Install-ExtensionPack.ps1 -Source D:\share\syslab-pack -OnlyBridge
.EXAMPLE
    # 直接从 GitHub Release 安装（推荐；私有仓库会自动用 git 已保存的凭据，公开仓库无需令牌）
    powershell -ExecutionPolicy Bypass -File scripts\Install-ExtensionPack.ps1 -GitHubRelease BlackTea-Lee/VScodeWithSyslab@v1.0.0
#>
[CmdletBinding(DefaultParameterSetName = 'Source')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Source')][string]$Source,
    [Parameter(Mandatory, ParameterSetName = 'GitHub')][string]$GitHubRelease,   # owner/repo@tag
    [string]$Token,
    [string]$VSCodeExe,
    [switch]$OnlyBridge,
    [switch]$SkipEnv,
    [switch]$SkipVerify,
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$kitRoot = Split-Path -Parent $scriptRoot
. (Join-Path $kitRoot 'bin\vscode-kit.ps1')

function Write-Step([string]$Text) { Write-Host ''; Write-Host "=== $Text ===" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "  [信息] $Text" -ForegroundColor Gray }
function Write-Warn2([string]$Text) { Write-Host "  [注意] $Text" -ForegroundColor Yellow }

$bridgeInfo = Get-BridgeExtensionInfo -KitRoot $kitRoot

function Get-RequestHeaders {
    $headers = @{}
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    return $headers
}

function Save-Url {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$OutFile)
    $headers = Get-RequestHeaders
    if ($headers.Count -gt 0) {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -Headers $headers -UseBasicParsing
    }
    else {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    }
}

# ---------------------------------------------------------------------------
# 1. 准备发布包目录
# ---------------------------------------------------------------------------
Write-Step '1/4 获取扩展发布包'
$tempDir = Join-Path $env:TEMP ("syslab-ext-pack-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$packDir = $null

try {
    $isUrl = $false
    if ($PSCmdlet.ParameterSetName -eq 'GitHub') {
        # ---- 从 GitHub Release 附件下载（公开/私有都走 API，私有需令牌） ----
        if ($GitHubRelease -notmatch '^(?<repo>[^@]+)@(?<tag>.+)$') {
            throw "-GitHubRelease 需要形如 owner/repo@v1.0.0，当前值为：$GitHubRelease"
        }
        $repoSpec = $Matches['repo']
        $tagSpec = $Matches['tag']
        $resolvedToken = Get-GitHubToken -Token $Token
        Write-Info "GitHub Release：$repoSpec@$tagSpec$(if ($resolvedToken) { '（已带令牌）' } else { '（匿名）' })"

        $releaseAssets = Get-GitHubReleaseAssets -Repository $repoSpec -Tag $tagSpec -Token $resolvedToken
        $packDir = Join-Path $tempDir 'gh-release'
        New-Item -ItemType Directory -Path $packDir -Force | Out-Null

        # 先取 manifest.json，据此决定要下载哪些扩展
        $manifestAsset = $releaseAssets | Where-Object { $_.name -eq 'manifest.json' } | Select-Object -First 1
        if ($manifestAsset) {
            Save-GitHubReleaseAsset -Asset $manifestAsset -OutFile (Join-Path $packDir 'manifest.json') -Token $resolvedToken | Out-Null
            Write-Ok '已下载 manifest.json'
        }
        $sumAsset = $releaseAssets | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1
        if ($sumAsset) {
            Save-GitHubReleaseAsset -Asset $sumAsset -OutFile (Join-Path $packDir 'SHA256SUMS.txt') -Token $resolvedToken | Out-Null
        }

        $wantedFiles = @()
        $localManifest = Join-Path $packDir 'manifest.json'
        if (Test-Path $localManifest) {
            $releaseManifest = Get-Content $localManifest -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($ext in $releaseManifest.extensions) {
                if ($OnlyBridge -and ($ext.id -ne $bridgeInfo.IdLower)) { continue }
                $wantedFiles += $ext.file
            }
        }
        else {
            $wantedFiles = $releaseAssets | Where-Object { $_.name -like '*.vsix' } | Select-Object -ExpandProperty name
        }

        foreach ($fileName in $wantedFiles) {
            $asset = $releaseAssets | Where-Object { $_.name -eq $fileName } | Select-Object -First 1
            if (-not $asset) { Write-Warn2 "Release 中没有附件 $fileName"; continue }
            Write-Info ("下载 {0}（{1:N1} MB）" -f $fileName, ($asset.size / 1MB))
            Save-GitHubReleaseAsset -Asset $asset -OutFile (Join-Path $packDir $fileName) -Token $resolvedToken | Out-Null
        }
    }
    else {
        $isUrl = $Source -match '^(https?)://'
    }
    if ($isUrl) {
        if ($Source -match '\.vsix$') {
            # 单个 VSIX
            $packDir = Join-Path $tempDir 'single'
            New-Item -ItemType Directory -Path $packDir -Force | Out-Null
            $file = Join-Path $packDir (Split-Path -Leaf $Source)
            Write-Info "下载 $Source"
            Save-Url -Url $Source -OutFile $file
        }
        elseif ($Source -match '\.zip$') {
            $zipFile = Join-Path $tempDir 'pack.zip'
            Write-Info "下载 $Source"
            Save-Url -Url $Source -OutFile $zipFile
            Expand-Archive -LiteralPath $zipFile -DestinationPath $tempDir -Force
            $packDir = $tempDir
        }
        else {
            # 基地址或 manifest.json 直链
            $base = $Source.TrimEnd('/')
            if ($base -match '\.json$') {
                $manifestUrl = $base
                $base = $base.Substring(0, $base.LastIndexOf('/'))
            }
            else {
                $manifestUrl = "$base/manifest.json"
            }
            $manifestFile = Join-Path $tempDir 'manifest.json'
            Write-Info "下载 $manifestUrl"
            Save-Url -Url $manifestUrl -OutFile $manifestFile
            $packDir = $tempDir
        }
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'Source') {
        $resolved = (Resolve-Path $Source).Path
        if (Test-Path $resolved -PathType Container) { $packDir = $resolved }
        elseif ($resolved -match '\.zip$') {
            Expand-Archive -LiteralPath $resolved -DestinationPath $tempDir -Force
            $packDir = $tempDir
        }
        else {
            $packDir = Split-Path -Parent $resolved
        }
        Write-Info "使用本地发布包：$packDir"
    }

    # 基地址模式：把 manifest 里列出的 VSIX 逐个下载
    $manifestPath = Join-Path $packDir 'manifest.json'
    if ($isUrl -and -not ($Source -match '\.vsix$') -and (Test-Path $manifestPath)) {
        $manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $base = $Source.TrimEnd('/')
        if ($base -match '\.json$' -or $base -match '\.zip$') { $base = $base.Substring(0, $base.LastIndexOf('/')) }
        foreach ($ext in $manifest.extensions) {
            if ($OnlyBridge -and ($ext.id -ne $bridgeInfo.IdLower)) { continue }
            $target = Join-Path $packDir $ext.file
            if (Test-Path $target) { continue }
            $url = "$base/$($ext.file)"
            Write-Info "下载 $($ext.file)"
            Save-Url -Url $url -OutFile $target
        }
    }
}
catch {
    Write-Error "获取发布包失败：$($_.Exception.Message)"
    exit 1
}

# ---------------------------------------------------------------------------
# 2. 校验
# ---------------------------------------------------------------------------
Write-Step '2/4 校验扩展包'
$manifestPath = Join-Path $packDir 'manifest.json'
$manifest = $null
if (Test-Path $manifestPath) {
    $manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Ok "manifest.json：$($manifest.packName) $($manifest.packVersion)（$($manifest.generatedAt)）"
    Write-Ok "源自：$($manifest.source.syslabTitle) $($manifest.source.syslabVersion) / Julia $($manifest.source.juliaVersion)"
}
else {
    Write-Warn2 '未找到 manifest.json，将安装目录下所有 .vsix'
}

$vsixList = @()
if ($manifest) {
    foreach ($ext in $manifest.extensions) {
        if ($OnlyBridge -and ($ext.id -ne $bridgeInfo.IdLower)) { continue }
        $file = Join-Path $packDir $ext.file
        if (-not (Test-Path $file)) {
            # -OnlyBridge 时本来就没下载其它扩展，这里不必报警
            if ($PSCmdlet.ParameterSetName -ne 'GitHub') { Write-Warn2 "缺少文件 $($ext.file)" }
            continue
        }
        if (-not $SkipVerify -and $ext.sha256) {
            $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower()
            if ($hash -ne $ext.sha256) {
                Write-Error "校验失败：$($ext.file)（期望 $($ext.sha256.Substring(0, 16))…，实际 $($hash.Substring(0, 16))…）"
                exit 1
            }
            Write-Ok "$($ext.id) v$($ext.version) 校验通过"
        }
        $vsixList += $file
    }
}
else {
    $vsixList = Get-ChildItem $packDir -Filter '*.vsix' | Select-Object -ExpandProperty FullName
}

if ($vsixList.Count -eq 0) { Write-Error '没有可安装的扩展包。'; exit 1 }

# ---------------------------------------------------------------------------
# 3. 安装
# ---------------------------------------------------------------------------
Write-Step '3/4 安装到 VS Code'
$vscode = Find-VSCodeInstall -Explicit $VSCodeExe
if (-not $vscode) { Write-Error '未找到 VS Code，可用 -VSCodeExe 指定 Code.exe。'; exit 1 }
$codeCmd = $vscode.CodeCmd
if (-not $codeCmd) { Write-Error '未找到 code.cmd，无法自动安装。'; exit 1 }
Write-Ok "VS Code：$($vscode.Exe) ($($vscode.Version))"

$extensionsDir = Join-Path $env:USERPROFILE '.vscode\extensions'
$staleCount = Repair-ExtensionCache -ExtensionsDir $extensionsDir
if ($staleCount -gt 0) { Write-Ok "已清理 extensions.json 中 $staleCount 条失效记录" }

$installed = 0
foreach ($vsix in $vsixList) {
    $name = [System.IO.Path]::GetFileName($vsix)
    $output = ''
    try {
        $output = ((& $codeCmd --install-extension $vsix --force 2>&1) | ForEach-Object { $_.ToString() }) -join "`n"
    }
    catch { $output = $_.Exception.Message }

    $leaf = [System.IO.Path]::GetFileNameWithoutExtension($name)
    $targetDir = Join-Path $extensionsDir $leaf
    if (($output -match 'successfully installed') -or (Test-Path (Join-Path $targetDir 'package.json'))) {
        Write-Ok "已安装 $name"
        $installed++
        Invoke-SyslabCompatPatch -ExtensionDir $targetDir | Out-Null
    }
    else {
        Write-Warn2 "安装失败 $name ：$($output.Trim())"
    }
}

# ---------------------------------------------------------------------------
# 4. 环境变量与设置
# ---------------------------------------------------------------------------
Write-Step '4/4 环境变量与 VS Code 设置'
if ($SkipEnv) {
    Write-Info '已跳过（-SkipEnv）。需要时运行：install.ps1 -SkipExtensions'
}
else {
    $installer = Join-Path $kitRoot 'install.ps1'
    if (Test-Path $installer) {
        Write-Info '调用 install.ps1 -SkipExtensions 写入 Syslab 环境变量与设置 ...'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installer -SkipExtensions
    }
    else {
        Write-Warn2 "未找到 $installer，请手动配置 Syslab 环境变量。"
    }
}

if (-not $KeepTemp -and $tempDir -and (Test-Path $tempDir) -and ($packDir -like "$tempDir*")) {
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "=== 完成：成功安装 $installed / $($vsixList.Count) 个扩展 ===" -ForegroundColor Green
Write-Host '  重启（或 Reload Window）VS Code 后即可使用；状态见 ~\.syslab-vscode\bridge-status.json' -ForegroundColor White
