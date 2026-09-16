# -----------------------------------------------------------------------------
# MWORKS Syslab × VS Code 快速上手示例（不绘图，纯环境验证）
#
# 运行方式：
#   * VS Code 中：Ctrl+F5（Syslab: 运行当前脚本）
#   * 终端中    ：scripts\Run-SyslabScript.ps1 samples\quick_start.jl
# -----------------------------------------------------------------------------

using TyBase
using TyMath
using LinearAlgebra

println("Julia 版本   : ", VERSION)
println("活跃环境     : ", Base.active_project())
println("Depot        : ", first(DEPOT_PATH))
println("Syslab 版本  : ", get(ENV, "SYSLAB_VERSION", "-"))
println("sin(pi/2)    : ", sin(pi / 2))

a = [1 2; 3 4]
println("矩阵 a       : ", a)
println("det(a)       : ", det(a))
println("a * a        : ", a * a)

x = range(0, 2pi; length = 5)
println("x            : ", collect(x))

println("SYSLAB_SCRIPT_OK")
println("Syslab 环境可用，脚本运行成功 ✓")
