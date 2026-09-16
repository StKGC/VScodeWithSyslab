#requires -version 5.1
<#
.SYNOPSIS
    Syslab-Bridge 工具包的公共辅助函数（VS Code 定位、扩展安装、JSONC 读写）。
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
