#requires -version 5.1
<#
.SYNOPSIS
    VScodeWithSyslab 工具包的公共辅助函数（VS Code 定位、扩展安装、JSONC 读写）。
.DESCRIPTION
    由 install.ps1 / uninstall.ps1 / scripts\*.ps1 dot-source 使用。
#>

# ---------------------------------------------------------------------------
# VS Code 定位
# ---------------------------------------------------------------------------
function Get-VSCodeDetails {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Exe)

    $exePath = (Resolve-Path $Exe).Path
    $installRoot = Split-Path -Parent $exePath

    # 新版 VS Code 使用资源目录：<installRoot>\<commit>\resources\app\product.json
    $productPath = $null
    $productCandidates = @()
    $productCandidates += (Join-Path $installRoot 'resources\app\product.json')
    Get-ChildItem $installRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $productCandidates += (Join-Path $_.FullName 'resources\app\product.json')
    }
    foreach ($candidate in $productCandidates) {
        if (Test-Path $candidate) { $productPath = $candidate; break }
    }
    if (-not $productPath) { return $null }

    $version = ''
    $nameShort = ''
    try {
        $product = Get-Content $productPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $version = [string]$product.version
        $nameShort = [string]$product.nameShort
    }
    catch { }

    $codeCmd = Join-Path $installRoot 'bin\code.cmd'
    [pscustomobject]@{
        Exe         = $exePath
        InstallRoot = $installRoot
        ProductJson = $productPath
        Version     = $version
        Name        = $nameShort
        CodeCmd     = $(if (Test-Path $codeCmd) { $codeCmd } else { $null })
    }
}

function Find-VSCodeInstall {
    [CmdletBinding()]
    param([string]$Explicit)

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Explicit) { $candidates.Add($Explicit) }

    # PATH 中的 code.cmd：<installRoot>\bin\code.cmd
    $codeCmd = Get-Command 'code.cmd' -ErrorAction SilentlyContinue
    if ($codeCmd -and $codeCmd.Source) {
        $installRoot = Split-Path -Parent (Split-Path -Parent $codeCmd.Source)
        $candidates.Add((Join-Path $installRoot 'Code.exe'))
    }

    foreach ($p in @(
            "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe",
            'C:\Program Files\Microsoft VS Code\Code.exe',
            'C:\Program Files (x86)\Microsoft VS Code\Code.exe',
            'D:\IDE\VScode\Application\Microsoft VS Code\Code.exe',
            'D:\Program Files\Microsoft VS Code\Code.exe',
            'D:\VSCode\Code.exe'
        )) {
        $candidates.Add($p)
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            $details = Get-VSCodeDetails -Exe $candidate
            if ($details) { return $details }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 桥接扩展信息（publisher / name / version 的唯一来源：extension\package.json）
#
# 想换发布者（例如上架商店用你自己的 publisher）时，只改 extension\package.json
# 里的 "publisher" 即可，各处脚本与文件名都会自动跟随。
# ---------------------------------------------------------------------------
function Get-BridgeExtensionInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$KitRoot)

    $pkgPath = Join-Path $KitRoot 'extension\package.json'
    if (-not (Test-Path $pkgPath)) { throw "未找到桥接扩展清单：$pkgPath" }
    $pkg = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $id = "$($pkg.publisher).$($pkg.name)"
    [pscustomobject]@{
        Publisher   = [string]$pkg.publisher
        Name        = [string]$pkg.name
        Version     = [string]$pkg.version
        DisplayName = [string]$pkg.displayName
        Id          = $id
        IdLower     = $id.ToLower()
        FolderName  = "$id-$($pkg.version)"
        VsixName    = "$id-$($pkg.version).vsix"
        VsixPath    = Join-Path $KitRoot ("vsix\$id-$($pkg.version).vsix")
    }
}

# ---------------------------------------------------------------------------
# 统一扩展发布者前缀（把 TongYuan.* 整合为 StKGC.*）
#
# 只作用于「暂存的扩展副本」（即打进 VSIX 的那一份），不改 MWORKS.Syslab 安装目录。
# 处理两类内容：
#   1) package.json 的 "publisher" 字段；
#   2) 各处对扩展 ID 的引用（含 extensionDependencies、when 条件里的正则、
#      以及 JS 产物里硬编码的同伴扩展 ID），例如 TongYuan.syslab-julia → StKGC.syslab-julia。
#
# 注意：**只替换「发行者.扩展名」这种完整 ID**，绝不替换裸的 TongYuan——
#       环境变量里的 C:/Users/Public/TongYuan 是 Syslab 的共享目录路径，动了会直接坏掉。
#
# 版权提醒：同元软控扩展的著作权仍归其所有，本改写仅用于自有环境的私有分发，
#           请勿把改写后的包公开上架到 VS Code Marketplace。
# ---------------------------------------------------------------------------
function Set-ExtensionPublisherPrefix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExtensionDir,
        [Parameter(Mandatory)][string]$Publisher,
        [string[]]$OldPublishers = @('TongYuan', 'tongyuan'),
        [string[]]$ExtensionNames = @('syslab-julia', 'julia-analyzer', 'tymlang-ide', 'app-designer', 'mworks-syslab-copilot')
    )

    $applied = New-Object System.Collections.Generic.List[string]

    function Set-FileTextPreservingBom {
        param([string]$Path, [string]$Text)
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($hasBom))
    }

    # 1) package.json 的 publisher 字段
    $pkgPath = Join-Path $ExtensionDir 'package.json'
    if (Test-Path $pkgPath) {
        $text = [System.IO.File]::ReadAllText($pkgPath, [System.Text.UTF8Encoding]::new($false))
        $updated = [regex]::Replace($text, '("publisher"\s*:\s*")[^"]*(")', "`${1}$Publisher`${2}")
        if ($updated -ne $text) {
            Set-FileTextPreservingBom -Path $pkgPath -Text $updated
            $applied.Add("package.json : publisher -> $Publisher")
        }
    }

    # 2) 扩展 ID 引用（package.json / JS 产物）
    $files = Get-ChildItem $ExtensionDir -Recurse -File -Include '*.js', '*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\node_modules\\' -and $_.Length -lt 50MB }

    foreach ($file in $files) {
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.UTF8Encoding]::new($false))
        $updated = $text
        foreach ($oldPublisher in $OldPublishers) {
            foreach ($extensionName in $ExtensionNames) {
                $updated = $updated.Replace("$oldPublisher.$extensionName", "$Publisher.$extensionName")
            }
        }
        if ($updated -ne $text) {
            Set-FileTextPreservingBom -Path $file.FullName -Text $updated
            $relative = $file.FullName.Substring($ExtensionDir.TrimEnd('\', '/').Length + 1)
            $applied.Add("$relative : 扩展 ID 前缀 -> $Publisher")
        }
    }

    return $applied
}

# ---------------------------------------------------------------------------
# 扩展安装（复制文件夹，等价于离线安装 VSIX）
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Syslab 扩展兼容性补丁
#
# VS Code 里可能同时存在注册了同名命令的第三方扩展（例如 mermaid-chart 也注册了
# 极通用的 `extension.refreshTreeView`），而 VS Code 对重复注册会直接抛异常：
#     Error: command 'extension.refreshTreeView' already exists
# Syslab 的 Julia 扩展在 activate 阶段注册该命令，一旦冲突就会整段激活失败
# （表现为 Julia 扩展不起作用）。这里把它改名到 Syslab 自己的命名空间。
#
# 只修改扩展自身的 package.json / dist 产物，不动 Syslab 安装目录。
# ---------------------------------------------------------------------------
function Update-FileTextIfMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Old,
        [Parameter(Mandatory)][string]$New
    )

    if (-not (Test-Path $Path)) { return $false }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
    if ($text.IndexOf($Old, [System.StringComparison]::Ordinal) -lt 0) { return $false }
    $text = $text.Replace($Old, $New)
    [System.IO.File]::WriteAllText($Path, $text, [System.Text.UTF8Encoding]::new($hasBom))
    return $true
}

function Invoke-SyslabCompatPatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExtensionDir)

    $applied = New-Object System.Collections.Generic.List[string]
    $renames = @(
        @{ Old = 'extension.refreshTreeView'; New = 'syslab.extension.refreshTreeView' }
    )

    foreach ($target in @('package.json', 'dist\extension.js')) {
        $path = Join-Path $ExtensionDir $target
        foreach ($rename in $renames) {
            if (Update-FileTextIfMatch -Path $path -Old $rename.Old -New $rename.New) {
                $applied.Add("$target : $($rename.Old) -> $($rename.New)")
            }
        }
    }
    return $applied
}

function Install-SyslabExtensionFolder {    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$ExtensionsDir,
        [string]$TargetName
    )

    if (-not (Test-Path (Join-Path $Source 'package.json'))) {
        Write-Warning "扩展目录缺少 package.json：$Source"
        return $null
    }

    $leaf = if ($TargetName) { $TargetName } else { Split-Path -Leaf $Source }
    $idx = $leaf.LastIndexOf('-')
    $extensionId = if ($idx -gt 0) { $leaf.Substring(0, $idx) } else { $leaf }
    $target = Join-Path $ExtensionsDir $leaf

    if (-not (Test-Path $ExtensionsDir)) {
        New-Item -ItemType Directory -Path $ExtensionsDir -Force | Out-Null
    }

    # 清理同 ID 的旧版本（避免 VS Code 同时加载两个版本）
    Get-ChildItem $ExtensionsDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $extensionId -or $_.Name -like "$extensionId-*" } |
        Where-Object { $_.FullName -ne $target } |
        ForEach-Object {
            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }

    if (Test-Path $target) {
        Remove-Item $target -Recurse -Force -ErrorAction SilentlyContinue
    }

    $robocopy = Get-Command 'robocopy.exe' -ErrorAction SilentlyContinue
    if ($robocopy) {
        & $robocopy.Source $Source $target /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
        if ($LASTEXITCODE -ge 8) {
            throw "复制扩展失败（robocopy 退出码 $LASTEXITCODE）：$Source -> $target"
        }
    }
    else {
        Copy-Item $Source $target -Recurse -Force
    }

    return $target
}

# ---------------------------------------------------------------------------
# JSONC 读写
# ---------------------------------------------------------------------------
function Remove-JsoncNoise {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $sb = New-Object System.Text.StringBuilder
    $inString = $false
    $escaped = $false
    $i = 0
    $len = $Text.Length
    while ($i -lt $len) {
        $c = $Text[$i]
        if ($inString) {
            [void]$sb.Append($c)
            if ($escaped) { $escaped = $false }
            elseif ($c -eq '\') { $escaped = $true }
            elseif ($c -eq '"') { $inString = $false }
            $i++
            continue
        }
        if ($c -eq '"') { $inString = $true; [void]$sb.Append($c); $i++; continue }
        if ($c -eq '/' -and ($i + 1) -lt $len) {
            $next = $Text[$i + 1]
            if ($next -eq '/') {
                while ($i -lt $len -and $Text[$i] -ne "`n") { $i++ }
                continue
            }
            if ($next -eq '*') {
                $i += 2
                while (($i + 1) -lt $len -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq '/')) { $i++ }
                $i += 2
                continue
            }
        }
        [void]$sb.Append($c)
        $i++
    }
    # 去掉对象/数组结尾的多余逗号
    return ([regex]::Replace($sb.ToString(), ',(\s*[}\]])', '$1'))
}

function ConvertTo-HashtableDeep {
    [CmdletBinding()]
    param($InputObject)

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $hash = @{}
        foreach ($key in $InputObject.Keys) { $hash[[string]$key] = ConvertTo-HashtableDeep $InputObject[$key] }
        return $hash
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $hash = @{}
        foreach ($prop in $InputObject.PSObject.Properties) { $hash[$prop.Name] = ConvertTo-HashtableDeep $prop.Value }
        return $hash
    }
    if (($InputObject -is [System.Collections.IEnumerable]) -and ($InputObject -isnot [string])) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $InputObject) { [void]$list.Add((ConvertTo-HashtableDeep $item)) }
        return , $list.ToArray()
    }
    return $InputObject
}

function Read-JsoncFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { return @{} }
    $text = Get-Content $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($text)) { return @{} }
    $clean = Remove-JsoncNoise -Text $text
    if ([string]::IsNullOrWhiteSpace($clean)) { return @{} }
    try {
        $obj = $clean | ConvertFrom-Json
    }
    catch {
        Write-Warning "无法解析 JSON/JSONC：$Path（$($_.Exception.Message)），将按空设置处理。"
        return @{}
    }
    $hash = ConvertTo-HashtableDeep $obj
    if ($null -eq $hash) { return @{} }
    return $hash
}

function Set-SettingDeep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Path,
        $Value
    )

    $parts = $Path -split '\.'
    $current = $Settings
    for ($i = 0; $i -lt ($parts.Length - 1); $i++) {
        $key = $parts[$i]
        if (-not $current.ContainsKey($key) -or -not ($current[$key] -is [hashtable])) {
            $current[$key] = @{}
        }
        $current = $current[$key]
    }
    $current[$parts[-1]] = $Value
}

function Remove-SettingDeep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Path
    )

    $parts = $Path -split '\.'
    $current = $Settings
    for ($i = 0; $i -lt ($parts.Length - 1); $i++) {
        $key = $parts[$i]
        if (-not $current.ContainsKey($key) -or -not ($current[$key] -is [hashtable])) { return }
        $current = $current[$key]
    }
    if ($current.ContainsKey($parts[-1])) { $current.Remove($parts[-1]) }
}

# ---------------------------------------------------------------------------
# 修复扩展缓存（extensions.json）
#
# VS Code 1.7x 以 %USERPROFILE%\.vscode\extensions\extensions.json 作为“已安装扩展”的权威记录。
# 若某条记录指向的目录已不存在（例如手工删除了目录），`code --install-extension` 会报
# “Please restart VS Code before reinstalling ...”。这里先把这类失效记录摘掉，安装即可继续。
# ---------------------------------------------------------------------------
function Repair-ExtensionCache {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExtensionsDir)

    $cachePath = Join-Path $ExtensionsDir 'extensions.json'
    if (-not (Test-Path $cachePath)) { return 0 }

    $json = Get-Content $cachePath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($json)) { return 0 }
    $entries = $json | ConvertFrom-Json
    if ($null -eq $entries) { return 0 }

    $kept = New-Object System.Collections.Generic.List[object]
    $removed = 0
    foreach ($entry in $entries) {
        $rel = $entry.relativeLocation
        if ($rel -and (Test-Path (Join-Path $ExtensionsDir $rel))) { $kept.Add($entry) }
        else { $removed++ }
    }
    if ($removed -eq 0) { return 0 }

    $items = @()
    foreach ($entry in $kept) { $items += (ConvertTo-Json -InputObject $entry -Depth 10 -Compress) }
    $out = "[`r`n" + ($items -join ",`r`n") + "`r`n]`r`n"
    [System.IO.File]::WriteAllText($cachePath, $out, [System.Text.UTF8Encoding]::new($false))
    return $removed
}

# ---------------------------------------------------------------------------
# 用「正斜杠」条目名打包 zip
#
# .NET Framework 的 ZipFile::CreateFromDirectory 在 Windows 上会把条目名写成
# `extension\package.json`（反斜杠）。这样的包在 Windows 上能被 VS Code 正常解压，
# 但在 Linux/macOS 上会被解成名字里带反斜杠的文件而安装失败，`unzip` 也一样。
# 因此这里自己写条目，统一用 `/`，保证 VSIX 与发布包跨平台可用。
# ---------------------------------------------------------------------------
function New-ZipArchiveFromDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$ZipPath
    )

    Add-Type -AssemblyName System.IO.Compression | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

    $source = (Resolve-Path $SourceDir).Path.TrimEnd('\', '/')
    $parent = Split-Path -Parent $ZipPath
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }

    $minTime = [datetime]::new(1980, 1, 1, 0, 0, 0)
    $maxTime = [datetime]::new(2107, 12, 31, 23, 59, 58)

    $zip = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $prefixLength = $source.Length + 1
        foreach ($file in (Get-ChildItem $source -Recurse -File | Sort-Object FullName)) {
            $relative = $file.FullName.Substring($prefixLength).Replace('\', '/')
            $entry = $zip.CreateEntry($relative, [System.IO.Compression.CompressionLevel]::Optimal)
            $stamp = $file.LastWriteTime
            if ($stamp -lt $minTime) { $stamp = $minTime }
            if ($stamp -gt $maxTime) { $stamp = $maxTime }
            $entry.LastWriteTime = $stamp
            $entryStream = $entry.Open()
            try {
                $fileStream = [System.IO.File]::OpenRead($file.FullName)
                try { $fileStream.CopyTo($entryStream) } finally { $fileStream.Dispose() }
            }
            finally { $entryStream.Dispose() }
        }
    }
    finally { $zip.Dispose() }

    return $ZipPath
}

# ---------------------------------------------------------------------------
# GitHub Release 支持（发布包放 Release 附件，避免 git 历史随发版变大）
#
#   · Publish-GitHubRelease   ：创建/复用 tag 对应的 Release，并上传（或覆盖）附件
#   · Get-GitHubReleaseAssets ：列出某 Release 的附件
#   · Save-GitHubReleaseAsset ：按附件 id 下载（私有仓库走 API + Accept: octet-stream）
#
# 令牌来源优先级：显式 -Token → $env:GITHUB_TOKEN / $env:GH_TOKEN → git 凭据管理器
# ---------------------------------------------------------------------------
function Get-GitHubToken {
    [CmdletBinding()]
    param([string]$Token)

    if ($Token) { return $Token }
    foreach ($name in 'GITHUB_TOKEN', 'GH_TOKEN') {
        $value = [System.Environment]::GetEnvironmentVariable($name)
        if ($value) { return $value }
    }
    try {
        $cred = ("protocol=https`nhost=github.com`n`n" | & git credential fill) 2>$null
        $stored = ($cred | Where-Object { $_ -like 'password=*' } | Select-Object -First 1)
        if ($stored) { return ($stored -replace '^password=', '') }
    }
    catch { }
    return $null
}

function Get-GitHubHeaders {
    [CmdletBinding()]
    param([string]$Token, [string]$Accept = 'application/vnd.github+json')

    $headers = @{ 'User-Agent' = 'VScodeWithSyslab'; Accept = $Accept }
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    return $headers
}

function Get-GitHubReleaseByTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repository,   # owner/repo
        [Parameter(Mandatory)][string]$Tag,
        [string]$Token
    )

    $headers = Get-GitHubHeaders -Token $Token
    try {
        return Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/tags/$Tag" `
            -Headers $headers -Method Get -TimeoutSec 120
    }
    catch {
        return $null
    }
}

function Publish-GitHubRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repository,          # owner/repo
        [Parameter(Mandatory)][string]$Tag,                 # 例如 v1.0.0
        [Parameter(Mandatory)][string[]]$AssetPaths,
        [string]$Name,
        [string]$Body = '',
        [string]$TargetCommitish = 'main',
        [string]$Token,
        [switch]$Draft,
        [switch]$Prerelease
    )

    $Token = Get-GitHubToken -Token $Token
    if (-not $Token) { throw '未找到 GitHub 令牌（可用 -Token、$env:GITHUB_TOKEN 或在 git 凭据管理器里登录过 GitHub）。' }
    if (-not $Name) { $Name = $Tag }

    $headers = Get-GitHubHeaders -Token $Token
    $release = Get-GitHubReleaseByTag -Repository $Repository -Tag $Tag -Token $Token

    if (-not $release) {
        Write-Host "  创建 Release $Tag ..."
        $payloadJson = @{
            tag_name         = $Tag
            target_commitish = $TargetCommitish
            name             = $Name
            body             = $Body
            draft            = [bool]$Draft
            prerelease       = [bool]$Prerelease
        } | ConvertTo-Json -Depth 5
        # 必须发 UTF-8 字节：PowerShell 5.1 以字符串发请求体时会把中文按非 UTF-8 编码，
        # 导致 GitHub 返回 "Problems parsing JSON"
        $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payloadJson)
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases" `
            -Headers $headers -Method Post -Body $payloadBytes `
            -ContentType 'application/json; charset=utf-8' -TimeoutSec 120
        Write-Host "  Release 已创建：$($release.html_url)"
    }
    else {
        Write-Host "  复用已有 Release：$($release.html_url)"
    }

    $uploaded = @()
    foreach ($path in $AssetPaths) {
        if (-not (Test-Path $path)) { Write-Warning "附件不存在，跳过：$path"; continue }
        $file = Get-Item $path
        $assetName = $file.Name

        # 同名附件先删掉，保证可重复执行
        $existing = $release.assets | Where-Object { $_.name -eq $assetName }
        foreach ($old in $existing) {
            Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/assets/$($old.id)" `
                -Headers $headers -Method Delete -TimeoutSec 120 | Out-Null
            Write-Host "  已删除同名旧附件 $assetName"
        }

        $uploadUrl = "https://uploads.github.com/repos/$Repository/releases/$($release.id)/assets?name=$([uri]::EscapeDataString($assetName))"
        Write-Host ("  上传 {0}（{1:N1} MB）..." -f $assetName, ($file.Length / 1MB))
        Invoke-RestMethod -Uri $uploadUrl -Headers $headers -Method Post -InFile $file.FullName `
            -ContentType 'application/octet-stream' -TimeoutSec 3600 | Out-Null
        $uploaded += $assetName
        Write-Host "    [OK] $assetName"
    }

    $release = Get-GitHubReleaseByTag -Repository $Repository -Tag $Tag -Token $Token
    return [pscustomobject]@{
        Tag       = $Tag
        HtmlUrl   = $release.html_url
        ReleaseId = $release.id
        Assets    = ($release.assets | Select-Object -ExpandProperty name)
        Uploaded  = $uploaded
    }
}

function Get-GitHubReleaseAssets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag,
        [string]$Token
    )

    $release = Get-GitHubReleaseByTag -Repository $Repository -Tag $Tag -Token (Get-GitHubToken -Token $Token)
    if (-not $release) { throw "未找到 Release：$Repository@$Tag" }
    return $release.assets
}

function Save-GitHubReleaseAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Asset,        # Get-GitHubReleaseAssets 返回的对象
        [Parameter(Mandatory)][string]$OutFile,
        [string]$Token
    )

    $Token = Get-GitHubToken -Token $Token
    # 附件下载走 API + octet-stream，公开/私有仓库都可用（私有必须带令牌）
    $headers = Get-GitHubHeaders -Token $Token -Accept 'application/octet-stream'
    Invoke-WebRequest -Uri $Asset.url -Headers $headers -OutFile $OutFile -UseBasicParsing -TimeoutSec 3600
    return $OutFile
}
