#requires -version 5.1
<#
.SYNOPSIS
    MWORKS Syslab × VS Code 环境自检。
.DESCRIPTION
    检查项：
      1. Syslab 安装与 Julia 运行时；
      2. 环境变量（与 Syslab 主程序一致）；
      3. 用 Syslab 的 Julia 运行示例脚本，加载 TyBase / TyMath / TyPlot；
      4. VS Code 中 Syslab 相关扩展是否安装到位。

.PARAMETER Quick
    跳过加载 TyBase / TyMath / TyPlot（较快）。

.PARAMETER TimeoutSeconds
    单次 julia 调用的超时时间，默认 600 秒（首次预编译可能较慢）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\Test-SyslabEnv.ps1
#>
[CmdletBinding()]
param(
    [switch]$Quick,
    [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Continue'
try {
    # 让 julia 的 UTF-8 输出在控制台上正确显示
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
}
catch { }
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$kitRoot = Split-Path -Parent $scriptRoot
. (Join-Path $kitRoot 'bin\syslab-env.ps1')
. (Join-Path $kitRoot 'bin\vscode-kit.ps1')

$bridgeInfo = Get-BridgeExtensionInfo -KitRoot $kitRoot

$script:Failures = 0
function Check([string]$Name, [scriptblock]$Body) {
    Write-Host ''
    Write-Host "--- $Name" -ForegroundColor Cyan
    try {
        $result = & $Body
        if ($result -eq $false) {
            Write-Host "  [失败] $Name" -ForegroundColor Red
            $script:Failures++
        }
        else {
            Write-Host "  [通过] $Name" -ForegroundColor Green
        }
    }
    catch {
        Write-Host "  [失败] $Name : $($_.Exception.Message)" -ForegroundColor Red
        $script:Failures++
    }
}

Write-Host '==============================================' -ForegroundColor White
Write-Host ' MWORKS Syslab × VS Code 环境自检' -ForegroundColor White
Write-Host '==============================================' -ForegroundColor White

$syslabEnv = $null
$juliaExe = $null

Check 'Syslab 安装与 Julia 运行时' {
    $script:syslabEnv = Get-SyslabEnvironment
    Write-Host "  Syslab      : $($script:syslabEnv.Info.SyslabHome)"
    Write-Host "  版本        : $($script:syslabEnv.Info.Title) $($script:syslabEnv.Info.SyslabVersion)"
    Write-Host "  Julia       : $($script:syslabEnv.Values.JULIA_HOME)"
    Write-Host "  Depot       : $($script:syslabEnv.Values.JULIA_DEPOT_PATH)"
    $script:juliaExe = Join-Path ($script:syslabEnv.Values.JULIA_HOME -replace '/', '\') 'bin\julia.exe'
    if (-not (Test-Path $script:juliaExe)) { throw "julia.exe 不存在：$($script:juliaExe)" }
    $true
}

Check '环境变量注入' {
    Set-SyslabEnvironment $script:syslabEnv
    foreach ($key in 'SYSLAB_HOME', 'JULIA_HOME', 'JULIA_DEPOT_PATH', 'TONGYUAN_PATH') {
        $value = [System.Environment]::GetEnvironmentVariable($key)
        Write-Host "  $key = $value"
        if (-not $value) { throw "环境变量 $key 未设置" }
    }
    if (-not ($env:PATH -like "*julia-1.10.10\bin*")) { Write-Host '  [注意] PATH 中未见 Syslab 的 julia\bin 目录' }
    $true
}

$projectDir = Join-Path ($syslabEnv.Values.JULIA_DEPOT_PATH -replace '/', '\') 'environments\v1.10'
$projectArg = "--project=$($projectDir -replace '\\', '/')"

Check 'julia --version' {
    $output = & $script:juliaExe $projectArg '--version' 2>&1 | Out-String
    Write-Host ("  " + $output.Trim())
    if ($output -notmatch 'julia version') { throw 'julia --version 输出异常' }
    $true
}

Check 'Syslab 默认环境（Julia 包）' {
    if ($Quick) {
        Write-Host '  [跳过] -Quick 模式不加载 TyBase/TyMath/TyPlot'
        return $true
    }
    Write-Host '  正在加载 TyBase / TyMath / TyPlot（首次运行可能需要预编译，请耐心等待）...'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # 用临时脚本文件而不是 -e 传参，避免 Windows 命令行对引号的二次解析
    $checkFile = Join-Path $env:TEMP 'syslab-package-check.jl'
    @'
using TyBase, TyMath, TyPlot
println("packages OK | active_project=", Base.active_project())
'@ | Set-Content -LiteralPath $checkFile -Encoding UTF8
    $output = & $script:juliaExe $projectArg $checkFile 2>&1 | Out-String
    $sw.Stop()
    Write-Host ("  " + ($output.Trim() -replace "`r?`n", "`n  "))
    Write-Host ("  耗时：{0:N1} 秒" -f $sw.Elapsed.TotalSeconds)
    if ($output -notmatch 'packages OK') { throw 'Syslab 包加载失败' }
    $true
}

Check '在 Syslab 环境中运行脚本（新进程）' {
    # 用临时脚本而不是示例文件：示例文件可能被用户改成需要图形界面的脚本
    $scriptFile = Join-Path $env:TEMP 'syslab-selfcheck.jl'
    @'
using TyBase, TyMath
using LinearAlgebra

println("active_project=", Base.active_project())
a = [1 2; 3 4]
println("det(a)=", det(a), "  sin(pi/2)=", sin(pi / 2))

# 顺带验证 TyPlot 的离屏导出（失败不影响脚本运行结论）
try
    @eval using TyPlot
    plot(0:0.1:2pi, sin.(0:0.1:2pi))
    exportgraphics(gca(), joinpath(tempdir(), "syslab-selfcheck.jpg"))
    println("TyPlot 导出图片 OK")
catch err
    println("TyPlot 绘图检查跳过：", sprint(showerror, err))
end

println("SYSLAB_SCRIPT_OK")
'@ | Set-Content -LiteralPath $scriptFile -Encoding UTF8
    $output = & $script:juliaExe $projectArg $scriptFile 2>&1 | Out-String
    Write-Host ("  " + ($output.Trim() -replace "`r?`n", "`n  "))
    if ($output -notmatch 'SYSLAB_SCRIPT_OK') { throw '脚本执行失败' }
    $true
}

Check 'VS Code 扩展安装情况' {
    $vscode = Find-VSCodeInstall
    if (-not $vscode) { throw '未找到 VS Code 安装' }
    Write-Host "  Code.exe    : $($vscode.Exe) ($($vscode.Version))"
    $extensionsDir = Join-Path $env:USERPROFILE '.vscode\extensions'
    $expected = @('tongyuan.syslab-julia', 'tongyuan.tymlang-ide', 'tongyuan.julia-analyzer', $bridgeInfo.IdLower)
    $missing = @()
    foreach ($id in $expected) {
        $dir = Get-ChildItem $extensionsDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $id -or $_.Name -like "$id-*" } |
            Select-Object -First 1
        if ($dir) { Write-Host "  [已安装] $($dir.Name)" }
        else { Write-Host "  [缺失]   $id" -ForegroundColor Yellow; $missing += $id }
    }
    if ($missing.Count -gt 0) {
        Write-Host '  提示：运行 install.ps1 即可安装缺失的扩展。' -ForegroundColor Yellow
        return $false
    }
    $true
}

Write-Host ''
Write-Host '==============================================' -ForegroundColor White
if ($script:Failures -eq 0) {
    Write-Host ' 全部检查通过：Syslab 环境可直接在 VS Code 中使用 ✓' -ForegroundColor Green
    Write-Host " 启动：$(Join-Path $kitRoot 'bin\Syslab-Code.cmd')" -ForegroundColor Yellow
    exit 0
}
else {
    Write-Host " 有 $($script:Failures) 项检查未通过，请查看上面的输出。" -ForegroundColor Red
    exit 1
}
