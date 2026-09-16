#requires -version 5.1
<#
.SYNOPSIS
    把 MWORKS.Syslab 的编辑器/脚本运行能力接入原生 VS Code。

.DESCRIPTION
    install.ps1 会完成以下工作：
      1. 探测 MWORKS.Syslab 安装目录与 Syslab 自带的 Julia 运行时；
      2. 生成环境文件 %USERPROFILE%\.syslab-vscode\env.json / env.cmd / env.ps1
         （与 Syslab 主程序 out/syslab-environment-win32.js 完全一致的变量集合）；
      3. 把 Syslab 自带扩展（tongyuan.syslab-julia / julia-analyzer / tymlang-ide / app-designer）
         安装到 VS Code 的用户扩展目录；
      4. 安装本工具包的桥接扩展 vscodewithsyslab（运行脚本 / REPL / 打开 Syslab / 环境自检）；
      5. 合并 VS Code 设置：julia 解释器路径、终端环境、Syslab 终端配置文件等。

.PARAMETER SyslabHome
    MWORKS.Syslab 安装目录，例如 "D:\Math\MWORKS\Syslab\Syslab 2026b"。默认自动探测。

.PARAMETER VSCodeExe
    VS Code 的 Code.exe 路径。默认自动探测（PATH 中的 code.cmd 或常见安装位置）。

.PARAMETER ExtensionsDir
    VS Code 用户扩展目录，默认 %USERPROFILE%\.vscode\extensions。

.PARAMETER UserSettingsDir
    VS Code 用户设置目录，默认 %APPDATA%\Code\User。

.PARAMETER PreloadPackages
    REPL / 终端启动时预加载的 Julia 包列表，默认 TyBase, TyMath, TyPlot。
    会同时写入 VS Code 的 julia.syslab.preloadPkgs、syslab.preloadPackages 与
    “Syslab Julia” 终端配置文件的启动参数。**这些包必须已装在 Syslab 默认环境**（@v1.10）里。

.PARAMETER IncludeCopilot
    一并安装 MWORKS Copilot 扩展（需要 Syslab 账号与服务器，默认不装）。

.PARAMETER SkipExtensions
    只生成环境文件与设置，不安装 Syslab 扩展。

.PARAMETER SkipSettings
    不修改 VS Code 的 settings.json。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1 -SyslabHome "D:\Math\MWORKS\Syslab\Syslab 2026b" -IncludeCopilot

.EXAMPLE
    # 新增一个预加载包（先用 Syslab 的 Julia 把包装进默认环境，再重跑安装脚本）
    powershell -ExecutionPolicy Bypass -File bin\Start-SyslabShell.ps1     # 在 REPL 里 Pkg.add("MyPkg")
    powershell -ExecutionPolicy Bypass -File install.ps1 -SkipExtensions `
        -PreloadPackages TyBase,TyMath,TyPlot,MyPkg
#>
[CmdletBinding()]
param(
    [string]$SyslabHome,
    [string]$VSCodeExe,
    [string]$ExtensionsDir,
    [string]$UserSettingsDir,
    [string[]]$PreloadPackages = @('TyBase', 'TyMath', 'TyPlot'),   # REPL/终端启动时预加载的 Julia 包
    [switch]$IncludeCopilot,
    [switch]$SkipExtensions,
    [switch]$SkipSettings
)

$ErrorActionPreference = 'Stop'
$KitRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $KitRoot 'bin\syslab-env.ps1')
. (Join-Path $KitRoot 'bin\vscode-kit.ps1')

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Write-Ok([string]$Text) { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "  [信息] $Text" -ForegroundColor Gray }
function Write-Warn2([string]$Text) { Write-Host "  [注意] $Text" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# 1. Syslab 环境
# ---------------------------------------------------------------------------
Write-Step '1/5 解析 MWORKS.Syslab 环境'
$syslabEnv = Get-SyslabEnvironment -SyslabHome $SyslabHome
$info = $syslabEnv.Info
$values = $syslabEnv.Values
Write-Ok "Syslab      : $($info.SyslabHome)"
Write-Ok "版本        : $($info.Title) $($info.SyslabVersion)"
Write-Ok "Julia       : $($values.JULIA_HOME)"
Write-Ok "Julia Depot : $($values.JULIA_DEPOT_PATH)"

$juliaExe = Join-Path ($values.JULIA_HOME -replace '/', '\') 'bin\julia.exe'
if (-not (Test-Path $juliaExe)) {
    throw "未找到 Syslab 自带的 julia.exe：$juliaExe"
}

# ---------------------------------------------------------------------------
# 2. 定位 VS Code
# ---------------------------------------------------------------------------
Write-Step '2/5 定位 VS Code'
$vscode = Find-VSCodeInstall -Explicit $VSCodeExe
if (-not $vscode) {
    throw '未找到 VS Code（Code.exe）。请用 -VSCodeExe 指定。'
}
Write-Ok "Code.exe    : $($vscode.Exe)"
Write-Ok "版本        : $($vscode.Version)"
if (-not $ExtensionsDir) {
    $ExtensionsDir = Join-Path $env:USERPROFILE '.vscode\extensions'
}
if (-not $UserSettingsDir) {
    $UserSettingsDir = Join-Path $env:APPDATA 'Code\User'
}
Write-Ok "扩展目录    : $ExtensionsDir"
Write-Ok "设置目录    : $UserSettingsDir"

# ---------------------------------------------------------------------------
# 3. 生成环境文件
# ---------------------------------------------------------------------------
Write-Step '3/5 生成 Syslab 环境文件'
$envDir = Join-Path $env:USERPROFILE '.syslab-vscode'
if (-not (Test-Path $envDir)) { New-Item -ItemType Directory -Path $envDir -Force | Out-Null }

$envJsonPath = Join-Path $envDir 'env.json'
$envPayload = [ordered]@{
    generatedAt  = (Get-Date).ToString('s')
    syslabHome   = $info.SyslabHome
    tongYuanPath = $info.TongYuanPath
    juliaVersion = $info.JuliaVersion
    syslabVersion = $info.SyslabVersion
    title        = $info.Title
    values       = $values
}
# 注意：不带 BOM 写入，Node/扩展侧的 JSON.parse 不接受 BOM
$envJsonText = ($envPayload | ConvertTo-Json -Depth 5)
[System.IO.File]::WriteAllText($envJsonPath, $envJsonText, [System.Text.UTF8Encoding]::new($false))
Write-Ok "env.json    : $envJsonPath"

# env.cmd（供 cmd 批处理使用）
$cmdLines = New-Object System.Collections.Generic.List[string]
$cmdLines.Add('@echo off')
$cmdLines.Add('REM MWORKS Syslab 环境变量（由 install.ps1 生成，勿手工修改）')
foreach ($key in $values.Keys) {
    $val = ([string]$values[$key]) -replace '%', '%%'
    $cmdLines.Add("set `"$key=$val`"")
}
$cmdLines.Add('')
$cmdLines | Set-Content -Path (Join-Path $envDir 'env.cmd') -Encoding ASCII

# env.ps1（供 PowerShell 使用）
$psLines = New-Object System.Collections.Generic.List[string]
$psLines.Add('# MWORKS Syslab 环境变量（由 install.ps1 生成，勿手工修改）')
foreach ($key in $values.Keys) {
    $val = ([string]$values[$key]) -replace "'", "''"
    $psLines.Add("`$env:$key = '$val'")
}
$psLines.Add('')
$psLines | Set-Content -Path (Join-Path $envDir 'env.ps1') -Encoding UTF8
Write-Ok "env.cmd     : $(Join-Path $envDir 'env.cmd')"
Write-Ok "env.ps1     : $(Join-Path $envDir 'env.ps1')"

# ---------------------------------------------------------------------------
# 4. 安装扩展（VSIX 离线安装：VS Code 1.7x 起不再识别手工拷贝的扩展目录）
# ---------------------------------------------------------------------------
$installedExtensions = @()
if (-not $SkipExtensions) {
    Write-Step '4/5 安装扩展到 VS Code'
    if (-not (Test-Path $ExtensionsDir)) { New-Item -ItemType Directory -Path $ExtensionsDir -Force | Out-Null }

    $wanted = @('tongyuan.syslab-julia-*', 'tongyuan.julia-analyzer-*', 'tongyuan.tymlang-ide-*', 'tongyuan.app-designer-*')
    if ($IncludeCopilot) { $wanted += 'tongyuan.mworks-syslab-copilot-*' }

    $tongYuanExtDir = Join-Path ($info.TongYuanPath -replace '/', '\') '.syslab-oss\extensions'
    $codeCmd = $vscode.CodeCmd
    $vsixDir = Join-Path $KitRoot 'vsix'

    if ($codeCmd) {
        Write-Info "使用 VSIX + code CLI 安装（code.cmd: $codeCmd）"

        $bridge = Get-BridgeExtensionInfo -KitRoot $KitRoot
        $syslabIds = @('syslab-julia', 'julia-analyzer', 'tymlang-ide', 'app-designer', 'mworks-syslab-copilot')
        $managedIds = @($syslabIds | ForEach-Object { "$($bridge.Publisher).$_".ToLower() })
        # 历次改名的旧 ID / 旧发布者，保留以便清理
        $managedIds += @($syslabIds | ForEach-Object { "tongyuan.$_" })
        $managedIds += @($bridge.IdLower, 'stkgc.syslab-bridge', 'syslab-community.syslab-bridge')

        # 4.0 清理“残缺安装”：目录存在但没有 package.json，说明上次安装中断，必须删掉重装
        foreach ($managedId in $managedIds) {
            Get-ChildItem $ExtensionsDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq $managedId -or $_.Name -like "$managedId-*" } |
                Where-Object { -not (Test-Path (Join-Path $_.FullName 'package.json')) } |
                ForEach-Object {
                    Write-Warn2 "发现残缺安装 $($_.Name)，删除后重新安装"
                    Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
        }

        # 4.1 修复扩展缓存：清理 extensions.json 中目录已不存在的“幽灵”记录
        $staleCount = Repair-ExtensionCache -ExtensionsDir $ExtensionsDir
        if ($staleCount -gt 0) {
            Write-Ok "已清理 extensions.json 中 $staleCount 条失效记录"
        }

        # 4.2 已安装的 Syslab 扩展：就地应用兼容补丁（VS Code 正在运行时无法重装，
        #     但只要补丁已生效，编辑/运行等主功能即可正常工作）
        $listedBefore = @()
        try { $listedBefore = & $codeCmd --list-extensions 2>&1 } catch { }
        foreach ($managedId in $managedIds) {
            Get-ChildItem $ExtensionsDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq $managedId -or $_.Name -like "$managedId-*" } |
                ForEach-Object {
                    $extDir = $_.FullName
                    $extName = $_.Name
                    foreach ($patchInfo in (Invoke-SyslabCompatPatch -ExtensionDir $extDir)) {
                        Write-Ok "兼容补丁 $extName ：$patchInfo"
                    }
                }
        }

        # 4.2 打包并安装 Syslab 自带扩展（打包时统一改写发布者前缀为 $($bridge.Publisher)）
        $vsixList = @()
        if (Test-Path $tongYuanExtDir) {
            $vsixList += & (Join-Path $KitRoot 'scripts\Build-SyslabVsix.ps1') -TongYuanExtensionsDir $tongYuanExtDir `
                -Only $wanted -Publisher $bridge.Publisher
        }
        else {
            Write-Warn2 "未找到 Syslab 的扩展目录：$tongYuanExtDir（跳过 Syslab 扩展安装）"
        }

        # 4.3 打包并安装桥接扩展
        $bridgeVsix = & (Join-Path $KitRoot 'scripts\New-SyslabVsix.ps1') -SourceDir (Join-Path $KitRoot 'extension') -OutputDir $vsixDir
        if ($bridgeVsix) { $vsixList += [string]$bridgeVsix }

        # 4.4 逐个安装（已安装且版本一致的直接跳过，避免 VS Code 运行时的文件占用）
        foreach ($vsix in ($vsixList | Where-Object { $_ -and (Test-Path $_) })) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($vsix)
            $targetDir = Join-Path $ExtensionsDir $name
            $lastDash = $name.LastIndexOf('-')
            $vsixId = if ($lastDash -gt 0) { $name.Substring(0, $lastDash) } else { $name }
            $alreadyListed = ($listedBefore -join "`n") -match [regex]::Escape($vsixId)
            $targetValid = Test-Path (Join-Path $targetDir 'package.json')
            if ($targetValid -and $alreadyListed) {
                Write-Ok "$name 已安装（跳过，已应用兼容补丁）"
                $installedExtensions += $name
                continue
            }
            if (Test-Path $targetDir) {
                Write-Info "$name 目标目录已存在，交由 code CLI 覆盖安装"
            }
            $installOutput = ''
            try {
                # 分开取回 stdout/stderr，避免 PowerShell 把 stderr 记录吞掉后丢失成功信息
                $installOutput = ((& $codeCmd --install-extension $vsix --force 2>&1) |
                        ForEach-Object { $_.ToString() }) -join "`n"
            }
            catch {
                $installOutput = $_.Exception.Message
            }
            $installSucceeded = ($installOutput -match 'successfully installed') -or (Test-Path $targetDir)
            if ($installSucceeded) {
                Write-Ok "已安装 $name"
                $installedExtensions += $name
                if (Test-Path $targetDir) { Invoke-SyslabCompatPatch -ExtensionDir $targetDir | Out-Null }
            }
            elseif ((Test-Path $targetDir) -and (($listedBefore -join "`n") -match [regex]::Escape($vsixId))) {
                # VS Code 正在运行时会拒绝重装（扩展文件被占用），但扩展本身已经装好
                Write-Ok "$name 已安装（VS Code 运行中，跳过重装）"
                $installedExtensions += $name
                Invoke-SyslabCompatPatch -ExtensionDir $targetDir | Out-Null
            }
            else {
                Write-Warn2 "安装失败 $name ：$($installOutput.Trim())"
                Write-Warn2 "提示：请关闭 VS Code 后重新运行 install.ps1（正在运行的 VS Code 会占用扩展文件）。"
            }
        }

        # 4.5 校验
        $listed = & $codeCmd --list-extensions 2>&1
        $expectIds = @("$($bridge.Publisher).syslab-julia", "$($bridge.Publisher).tymlang-ide",
            "$($bridge.Publisher).julia-analyzer", $bridge.IdLower)
        foreach ($id in $expectIds) {
            if ($listed -match [regex]::Escape($id)) { Write-Ok "VS Code 已识别 $id" }
            else { Write-Warn2 "VS Code 未识别 $id（可稍后在扩展面板中确认）" }
        }

        # 4.6 按当前环境刷新「预加载包」下拉候选（enum），让设置页里只出现本机真能 using 的包
        $enumScript = Join-Path $KitRoot 'scripts\Update-PreloadEnum.ps1'
        if (Test-Path $enumScript) {
            try {
                & powershell -NoProfile -ExecutionPolicy Bypass -File $enumScript -ExtensionsDir $ExtensionsDir |
                    ForEach-Object { Write-Host "  $_" }
            }
            catch {
                Write-Warn2 "刷新预加载候选失败（不影响安装）：$($_.Exception.Message)"
            }
        }
    }
    else {
        Write-Warn2 '未找到 code.cmd，退回到复制扩展目录的方式（仅旧版 VS Code 有效）'
        if (Test-Path $tongYuanExtDir) {
            foreach ($pattern in $wanted) {
                $source = Get-ChildItem $tongYuanExtDir -Directory -Filter $pattern -ErrorAction SilentlyContinue |
                    Sort-Object Name -Descending | Select-Object -First 1
                if (-not $source) { Write-Warn2 "未找到扩展：$pattern"; continue }
                $target = Install-SyslabExtensionFolder -Source $source.FullName -ExtensionsDir $ExtensionsDir
                if ($target) { Write-Ok "已复制 $([System.IO.Path]::GetFileName($target))" }
            }
        }
        $bridgeTarget = Install-SyslabExtensionFolder -Source (Join-Path $KitRoot 'extension') -ExtensionsDir $ExtensionsDir `
            -TargetName $bridge.FolderName
        if ($bridgeTarget) { Write-Ok "已复制 $($bridge.FolderName)" }
    }
}
else {
    Write-Step '4/5 跳过扩展安装（-SkipExtensions）'
}

# ---------------------------------------------------------------------------
# 5. 合并 VS Code 设置
# ---------------------------------------------------------------------------
if (-not $SkipSettings) {
    Write-Step '5/5 写入 VS Code 用户设置'
    if (-not (Test-Path $UserSettingsDir)) { New-Item -ItemType Directory -Path $UserSettingsDir -Force | Out-Null }
    $settingsPath = Join-Path $UserSettingsDir 'settings.json'
    $backupPath = "$settingsPath.syslab-bak"
    if ((Test-Path $settingsPath) -and -not (Test-Path $backupPath)) {
        Copy-Item $settingsPath $backupPath -Force
        Write-Info "已备份原设置：$backupPath"
    }

    $settings = Read-JsoncFile -Path $settingsPath
    if ($null -eq $settings) { $settings = @{} }

    $juliaExeFwd = ($juliaExe -replace '\\', '/')
    $projectDir = Join-Path ($values.JULIA_DEPOT_PATH -replace '/', '\') 'environments\v1.10'
    $projectDirFwd = ($projectDir -replace '\\', '/')

    $terminalEnv = [ordered]@{}
    foreach ($key in 'SYSLAB_HOME', 'TONGYUAN_PATH', 'JULIA_HOME', 'SYSLAB_JULIA_PATH', 'JULIA_DEPOT_PATH',
        'PATH', 'PYTHON', 'PYTHONNOUSERSITE', 'KMP_DUPLICATE_LIB_OK', 'JULIA_CONDAPKG_BACKEND',
        'PYTHON_JULIAPKG_OFFLINE', 'JULIA_PYTHONCALL_EXE', 'TYPY_JL_EXE', 'BITANSWER_ROOT_PATH',
        'JULIA_PKG_PRESERVE_TIERED_INSTALLED', 'SYSLAB_VERSION', 'TYPLOT_INTERACTIVE', 'JULIA_USE_FLISP_PARSER') {
        $terminalEnv[$key] = [string]$values[$key]
    }

    # -File 调用时 "A,B,C" 会作为单个字符串传入：统一拆分/去空白，兼容数组与逗号串两种写法
    $preloadList = @($PreloadPackages | ForEach-Object { ([string]$_ -split ',') } |
            ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($preloadList.Count -eq 0) { $preloadList = @('TyBase', 'TyMath', 'TyPlot') }
    $preloadExpr = 'using ' + ($preloadList -join ', ')

    Set-SettingDeep $settings 'julia.executablePath' $juliaExeFwd
    Set-SettingDeep $settings 'julia.syslab.logPath' ([string]$info.LogsPath)
    Set-SettingDeep $settings 'julia.syslab.simulationResultPath' ''
    Set-SettingDeep $settings 'julia.syslab.preloadPkgs' $preloadList          # Syslab Julia 扩展（REPL 启动时加载）
    Set-SettingDeep $settings 'syslab.preloadPackages' $preloadList            # 桥接扩展（终端 profile / 环境自检）
    Set-SettingDeep $settings 'julia.syslab.repl.defaultStart' $true
    Set-SettingDeep $settings 'syslab.envFile' $envJsonPath
    Set-SettingDeep $settings 'syslab.juliaExecutable' $juliaExeFwd
    Set-SettingDeep $settings 'syslab.projectPath' $projectDirFwd
    Set-SettingDeep $settings 'syslab.syslabExecutable' (Join-Path $info.SyslabHome 'Bin\syslab.exe')
    Set-SettingDeep $settings 'terminal.integrated.env.windows' $terminalEnv

    # 终端配置文件：在 VS Code 里直接选择 “Syslab Julia”
    if (-not $settings.ContainsKey('terminal.integrated.profiles.windows')) {
        $settings['terminal.integrated.profiles.windows'] = @{}
    }
    $profiles = $settings['terminal.integrated.profiles.windows']
    $profiles['Syslab Julia'] = [ordered]@{
        path = $juliaExeFwd
        args = @("--project=$projectDirFwd", '-i', '--banner=no', '-e', $preloadExpr)
        env  = $terminalEnv
        icon = 'beaker'
    }
    Write-Ok ("预加载包    : {0}" -f ($preloadList -join ', '))

    # .tym 关联到 M 语言（不覆盖 .m，避免与 MATLAB 扩展冲突）
    if (-not $settings.ContainsKey('files.associations')) { $settings['files.associations'] = @{} }
    $settings['files.associations']['*.tym'] = 'mlang'

    $settings | ConvertTo-Json -Depth 20 | Set-Content -Path $settingsPath -Encoding UTF8
    Write-Ok "settings.json 已更新：$settingsPath"
}
else {
    Write-Step '5/5 跳过设置写入（-SkipSettings）'
}

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
Write-Step '安装完成'
Write-Host "  Syslab 自带的 Julia/Syslab 扩展 + $($bridge.Id) 已就绪。" -ForegroundColor Green
Write-Host ''
Write-Host '  推荐打开方式（带完整 Syslab 环境启动 VS Code）：' -ForegroundColor White
Write-Host "    $(Join-Path $KitRoot 'bin\Syslab-Code.cmd')" -ForegroundColor Yellow
Write-Host ''
Write-Host '  也可以直接双击/命令行启动 Code.exe，终端里同样带有 Syslab 环境。' -ForegroundColor White
Write-Host ''
Write-Host '  下一步：' -ForegroundColor White
Write-Host '    1) 用 Syslab-Code.cmd 打开一个文件夹；'
Write-Host '    2) 打开 .jl 文件，按 Ctrl+F5（或命令面板 “Syslab: 运行当前脚本”）运行；'
Write-Host '    3) 命令面板 “Syslab: 环境自检” 可确认 Julia/包是否正常。'
Write-Host ''
Write-Host '  自检命令：' -ForegroundColor White
Write-Host "    powershell -ExecutionPolicy Bypass -File `"$(Join-Path $KitRoot 'scripts\Test-SyslabEnv.ps1')`"" -ForegroundColor Yellow
