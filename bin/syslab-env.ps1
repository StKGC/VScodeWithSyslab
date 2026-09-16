#requires -version 5.1
<#
.SYNOPSIS
    解析 MWORKS.Syslab 的安装位置与运行环境（与 Syslab 主程序 out/syslab-environment-win32.js 保持一致）。

.DESCRIPTION
    本脚本可被其它脚本 dot-source 使用：

        . "$PSScriptRoot\syslab-env.ps1"
        $syslabEnv = Get-SyslabEnvironment      # 得到 Info / Values
        Set-SyslabEnvironment $syslabEnv        # 写入当前进程环境（含 PATH）

    也可以直接运行，查看解析结果：

        powershell -ExecutionPolicy Bypass -File bin\syslab-env.ps1

.NOTES
    只读取 Syslab 安装信息，不修改系统环境变量、不写注册表。
#>

# ---------------------------------------------------------------------------
# 1. 定位 Syslab 安装目录
# ---------------------------------------------------------------------------
function Find-SyslabHome {
    [CmdletBinding()]
    param(
        [string]$Explicit
    )

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Explicit) { $candidates.Add($Explicit) }
    if ($env:SYSLAB_HOME) { $candidates.Add($env:SYSLAB_HOME) }

    # 注册表卸载信息里带安装路径
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($key in $uninstallKeys) {
        foreach ($item in @(Get-ItemProperty $key -ErrorAction SilentlyContinue)) {
            $nameProp = $item.PSObject.Properties['DisplayName']
            $uninstProp = $item.PSObject.Properties['UninstallString']
            if (-not $nameProp -or -not $uninstProp) { continue }
            if ([string]$nameProp.Value -notmatch 'MWORKS\.Syslab') { continue }
            if (-not $uninstProp.Value) { continue }
            $dir = Split-Path -Parent ([string]$uninstProp.Value).Trim('"')
            if ($dir) { $candidates.Add($dir) }
        }
    }

    # 常见安装位置
    foreach ($root in @('D:\Math\MWORKS\Syslab', 'C:\Math\MWORKS\Syslab', 'D:\MWORKS\Syslab', 'C:\MWORKS\Syslab')) {
        if (Test-Path $root) {
            Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'Syslab*' } |
                ForEach-Object { $candidates.Add($_.FullName) }
        }
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path (Join-Path $candidate 'Bin\resources\app\product.json'))) {
            return (Resolve-Path $candidate).Path
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 2. 读取 product.json 中的 Syslab 专有字段
# ---------------------------------------------------------------------------
function Get-SyslabProductInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SyslabHome)

    $productPath = Join-Path $SyslabHome 'Bin\resources\app\product.json'
    if (-not (Test-Path $productPath)) {
        throw "未找到 Syslab 主程序清单：$productPath"
    }
    $product = Get-Content $productPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $tongYuanPath = $product.syslabUserDataPath
    if (-not $tongYuanPath) {
        $tongYuanPath = 'C:\Users\Public\TongYuan'
        Write-Warning "product.json 缺少 syslabUserDataPath，回退到 $tongYuanPath"
    }

    [pscustomobject]@{
        SyslabHome    = $SyslabHome
        TongYuanPath  = ($tongYuanPath -replace '\\', '/').TrimEnd('/')
        JuliaVersion  = $product.juliaVersion
        SyslabVersion = $product.syslabVersion
        CachePath     = [string]($product.syslabCachePath -replace '\\', '/')
        LogsPath      = [string]($product.syslabLogsPath -replace '\\', '/')
        VSCodeVersion = $product.version
        Title         = [string]$product.syslabTitleName
    }
}

# ---------------------------------------------------------------------------
# 3. 计算环境变量（对齐 syslab-environment-win32.js）
# ---------------------------------------------------------------------------
function Get-SyslabEnvironment {
    [CmdletBinding()]
    param(
        [string]$SyslabHome,
        [string]$TongYuanPath,
        [switch]$KeepUserPython
    )

    if (-not $SyslabHome) { $SyslabHome = Find-SyslabHome }
    if (-not $SyslabHome) { throw '未找到 MWORKS.Syslab 安装目录，请用 -SyslabHome 显式指定。' }

    $info = Get-SyslabProductInfo -SyslabHome $SyslabHome
    if ($TongYuanPath) {
        $info.TongYuanPath = ($TongYuanPath -replace '\\', '/').TrimEnd('/')
    }

    $juliaHome      = "$($info.TongYuanPath)/$($info.JuliaVersion)"
    $juliaDepot     = "$($info.TongYuanPath)/.julia"
    $syslabJuliaDir = "$($info.TongYuanPath)/syslab-julia"
    $conda3         = "$juliaDepot/miniforge3"

    # PATH 前缀：只加入真实存在的目录，避免污染 PATH
    $pathParts = New-Object System.Collections.Generic.List[string]
    foreach ($p in @(
            "$juliaHome/bin",
            "$juliaHome/lib",
            "$juliaHome/lib/julia",
            "$SyslabHome/Tools/Git/cmd",
            "$SyslabHome/Tools/Git/usr/bin",
            "$SyslabHome/Tools/Git/mingw64/bin",
            "$SyslabHome/Tools/PortableGit/cmd",
            "$SyslabHome/Tools/PortableGit/usr/bin",
            "$SyslabHome/Tools/SyslabCC",
            "$SyslabHome/Tools/zig",
            "$SyslabHome/Tools/TyMLangDist"
        )) {
        if (Test-Path ($p -replace '/', '\')) { $pathParts.Add($p) }
    }

    $pythonExe = "$conda3/python.exe"
    $userPython = $env:TY_PYTHON_EXE
    if ($userPython) {
        $pythonExe = $userPython
        if (-not $KeepUserPython) {
            $pathParts.Add((Split-Path -Parent $userPython))
        }
    }
    elseif (Test-Path ($conda3 -replace '/', '\')) {
        foreach ($p in @(
                $conda3,
                "$conda3/Library/mingw-w64/bin",
                "$conda3/Library/usr/bin",
                "$conda3/Library/bin",
                "$conda3/Scripts",
                "$conda3/bin"
            )) {
            if (Test-Path ($p -replace '/', '\')) { $pathParts.Add($p) }
        }
    }

    $pathParts.Add($env:PATH)

    $values = [ordered]@{
        SYSLAB_HOME                         = $SyslabHome
        TONGYUAN_PATH                       = $info.TongYuanPath
        JULIA_HOME                          = $juliaHome
        SYSLAB_JULIA_PATH                   = $syslabJuliaDir
        JULIA_DEPOT_PATH                    = $juliaDepot
        PATH                                = ($pathParts -join ';')
        PYTHON                              = $pythonExe
        PYTHONNOUSERSITE                    = '1'
        KMP_DUPLICATE_LIB_OK                = 'TRUE'
        JULIA_CONDAPKG_BACKEND              = 'Null'
        PYTHON_JULIAPKG_OFFLINE             = 'yes'
        JULIA_PYTHONCALL_EXE                = '@PyCall'
        TYPY_JL_EXE                         = "$juliaHome/bin/julia.exe"
        BITANSWER_ROOT_PATH                 = $info.CachePath
        JULIA_PKG_PRESERVE_TIERED_INSTALLED = 'true'
        SYSLAB_VERSION                      = $info.SyslabVersion
        TYPLOT_INTERACTIVE                  = 'true'
        JULIA_USE_FLISP_PARSER              = '1'
    }

    [pscustomobject]@{
        Info   = $info
        Values = $values
    }
}

function Set-SyslabEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Environment)

    if ($Environment.PSObject.Properties['Values']) {
        $Environment = $Environment.Values
    }
    foreach ($key in $Environment.Keys) {
        Set-Item -Path "Env:$key" -Value ([string]$Environment[$key])
    }
    # Syslab 启动时会清掉这些变量，否则 Python/Qt 会和 Syslab 内置环境冲突
    foreach ($name in 'PYTHONPATH', 'PYTHONHOME', 'QT_QPA_PLATFORM_PLUGIN_PATH') {
        if (Test-Path "Env:$name") { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
    }
    if ($env:TERM -eq 'dumb') { Remove-Item Env:TERM -ErrorAction SilentlyContinue }
}

function Get-SyslabJuliaExe {
    [CmdletBinding()]
    param([string]$SyslabHome)
    $envInfo = Get-SyslabEnvironment -SyslabHome $SyslabHome
    return "$($envInfo.Values.JULIA_HOME)/bin/julia.exe"
}

# ---------------------------------------------------------------------------
# 直接运行：输出解析结果
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $resolved = Get-SyslabEnvironment
        Write-Host '=== MWORKS.Syslab 环境 ===' -ForegroundColor Cyan
        $resolved.Info | Format-List
        foreach ($entry in $resolved.Values.GetEnumerator()) {
            if ($entry.Key -ne 'PATH') {
                '{0,-36} = {1}' -f $entry.Key, $entry.Value
            }
        }
        $head = ($resolved.Values.PATH -split ';')[0..2] -join ';'
        '{0,-36} = {1}' -f 'PATH(前3段)', $head
    }
    catch {
        Write-Error $_
        exit 1
    }
}
