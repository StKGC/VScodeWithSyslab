#requires -version 5.1
<#
.SYNOPSIS
    把一个扩展目录打包成 VSIX（离线安装包）。
.DESCRIPTION
    VS Code 1.7x 之后，扩展目录（%USERPROFILE%\.vscode\extensions）不再接受“手工拷贝文件夹”，
    必须通过 `code --install-extension xxx.vsix` 走官方安装流程。本脚本负责生成这种 VSIX：

        <临时目录>\extension\            扩展全部文件
        <临时目录>\extension.vsixmanifest
        <临时目录>\[Content_Types].xml

.PARAMETER SourceDir
    扩展目录（含 package.json）。

.PARAMETER OutputDir
    VSIX 输出目录，默认 <工具包>\vsix。

.PARAMETER ManifestPath
    使用现成的 vsixmanifest（如 Syslab 扩展目录内的 .vsixmanifest）。不指定则自动生成。

.PARAMETER Publisher / Name / Version / DisplayName
    自动生成 manifest 时使用；默认从 package.json 读取。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\New-SyslabVsix.ps1 -SourceDir "C:\...\tongyuan.syslab-julia-26.1.0"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceDir,
    [string]$OutputDir,
    [string]$ManifestPath,
    [string]$Publisher,
    [string]$Name,
    [string]$Version,
    [string]$DisplayName,
    [string]$Engine,
    [switch]$Force,
    [switch]$KeepStaging
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$kitRoot = Split-Path -Parent $scriptRoot
. (Join-Path $kitRoot 'bin\vscode-kit.ps1')
if (-not $OutputDir) { $OutputDir = Join-Path $kitRoot 'vsix' }

Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

$source = (Resolve-Path $SourceDir).Path
if (-not (Test-Path (Join-Path $source 'package.json'))) { throw "不是扩展目录（缺少 package.json）：$source" }

# ---- 读取 package.json 里的基础信息（用正则，兼容重复键等不规范写法） ----
$packageText = Get-Content (Join-Path $source 'package.json') -Raw -Encoding UTF8
function Get-JsonField([string]$text, [string]$field) {
    $m = [regex]::Match($text, '"' + [regex]::Escape($field) + '"\s*:\s*"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}
$sourcePublisher = Get-JsonField $packageText 'publisher'
if (-not $Publisher) { $Publisher = $sourcePublisher }
if (-not $Name) { $Name = Get-JsonField $packageText 'name' }
if (-not $Version) { $Version = Get-JsonField $packageText 'version' }
if (-not $DisplayName) {
    $DisplayName = Get-JsonField $packageText 'displayName'
    if (-not $DisplayName) { $DisplayName = $Name }
}
$licenseMatch = [regex]::Match($packageText, '"license"\s*:\s*"([^"]*)"')
$licenseField = if ($licenseMatch.Success) { $licenseMatch.Groups[1].Value } else { '' }
if (-not $Engine) {
    $engineMatch = [regex]::Match($packageText, '"vscode"\s*:\s*"([^"]*)"')
    $Engine = if ($engineMatch.Success) { $engineMatch.Groups[1].Value } else { '^1.75.0' }
}

if (-not $Publisher -or -not $Name -or -not $Version) {
    throw "无法从 package.json 解析 publisher/name/version：$source"
}

# ---- 目标文件与复用判断 ----
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$vsixPath = Join-Path $OutputDir "$Publisher.$Name-$Version.vsix"
if ((Test-Path $vsixPath) -and -not $Force) {
    $newestSource = (Get-ChildItem $source -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    if ((Get-Item $vsixPath).LastWriteTime -gt $newestSource) {
        Write-Host "复用已有 VSIX：$vsixPath" -ForegroundColor Green
        return $vsixPath
    }
}
if (Test-Path $vsixPath) { Remove-Item $vsixPath -Force }

# ---- 准备暂存目录 ----
$staging = Join-Path ([System.IO.Path]::GetTempPath()) ("syslab-vsix-" + [guid]::NewGuid().ToString('N'))
$stageExtension = Join-Path $staging 'extension'
New-Item -ItemType Directory -Path $stageExtension -Force | Out-Null

Write-Host "打包扩展：$Publisher.$Name-$Version" -ForegroundColor Cyan
Write-Host "  源目录：$source"
Write-Host "  暂存  ：$staging"

& robocopy $source $stageExtension /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
if ($LASTEXITCODE -ge 8) { throw "复制扩展文件失败（robocopy 退出码 $LASTEXITCODE）" }

# ---- 兼容性补丁（只作用于暂存副本，不改 Syslab 安装目录） ----
foreach ($patchInfo in (Invoke-SyslabCompatPatch -ExtensionDir $stageExtension)) {
    Write-Host "  兼容补丁：$patchInfo" -ForegroundColor Yellow
}

# ---- 统一发布者前缀（例如 TongYuan.* → StKGC.*，同样只改暂存副本） ----
if ($Publisher -and $sourcePublisher -and ($Publisher -ne $sourcePublisher)) {
    foreach ($prefixInfo in (Set-ExtensionPublisherPrefix -ExtensionDir $stageExtension -Publisher $Publisher)) {
        Write-Host "  发布者前缀：$prefixInfo" -ForegroundColor Yellow
    }
}

# ---- extension.vsixmanifest ----
$targetManifest = Join-Path $staging 'extension.vsixmanifest'
if ($ManifestPath -and (Test-Path $ManifestPath)) {
    Copy-Item $ManifestPath $targetManifest -Force
}
elseif (Test-Path (Join-Path $source '.vsixmanifest')) {
    Copy-Item (Join-Path $source '.vsixmanifest') $targetManifest -Force
}
else {
    # 生成一个最小可用的 manifest（Assets 只声明确实存在的文件）
    $assets = New-Object System.Collections.Generic.List[string]
    $assets.Add('<Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" />')
    foreach ($pair in @(@('readme.md', 'Microsoft.VisualStudio.Services.Content.Details'),
            @('README.md', 'Microsoft.VisualStudio.Services.Content.Details'),
            @('changelog.md', 'Microsoft.VisualStudio.Services.Content.Changelog'),
            @('CHANGELOG.md', 'Microsoft.VisualStudio.Services.Content.Changelog'))) {
        $candidate = Join-Path $source $pair[0]
        if (Test-Path $candidate) {
            $assets.Add("<Asset Type=`"$($pair[1])`" Path=`"extension/$($pair[0])`" Addressable=`"true`" />")
        }
    }
    $licenseLine = ''
    if ($licenseField -and (Test-Path (Join-Path $source $licenseField))) {
        $assets.Add("<Asset Type=`"Microsoft.VisualStudio.Services.Content.License`" Path=`"extension/$licenseField`" Addressable=`"true`" />")
        $licenseLine = "<License>extension/$licenseField</License>"
    }
    $manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id="$Name" Version="$Version" Publisher="$Publisher" />
    <DisplayName>$DisplayName</DisplayName>
    <Description xml:space="preserve">$DisplayName (repacked for offline install)</Description>
    <Categories>Other</Categories>
    <GalleryFlags>Public</GalleryFlags>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="$Engine" />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionDependencies" Value="" />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionPack" Value="" />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="workspace" />
      <Property Id="Microsoft.VisualStudio.Services.Content.Pricing" Value="Free" />
    </Properties>
    $licenseLine
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code"/>
  </Installation>
  <Dependencies/>
  <Assets>
    $($assets -join "`r`n    ")
  </Assets>
</PackageManifest>
"@
    Set-Content -LiteralPath $targetManifest -Value $manifest -Encoding UTF8
}

# ---- [Content_Types].xml ----
$contentTypes = @'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension=".vsixmanifest" ContentType="text/xml"/>
  <Default Extension=".json" ContentType="application/json"/>
  <Default Extension=".js" ContentType="application/javascript"/>
  <Default Extension=".md" ContentType="text/markdown"/>
  <Default Extension=".txt" ContentType="text/plain"/>
  <Default Extension=".png" ContentType="image/png"/>
</Types>
'@
Set-Content -LiteralPath (Join-Path $staging '[Content_Types].xml') -Value $contentTypes -Encoding UTF8

# ---- 压缩为 VSIX（条目统一用正斜杠，保证 Linux/macOS 上也能正确解压） ----
New-ZipArchiveFromDirectory -SourceDir $staging -ZipPath $vsixPath | Out-Null

$sizeMb = [Math]::Round((Get-Item $vsixPath).Length / 1MB, 1)
Write-Host "  生成  ：$vsixPath ($sizeMb MB)" -ForegroundColor Green

if (-not $KeepStaging) { Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue }

# 输出路径供调用方使用
return $vsixPath
