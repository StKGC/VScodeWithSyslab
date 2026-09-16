# -----------------------------------------------------------------------------
# MWORKS Syslab × VS Code 绘图示例（TyPlot）
#
# 说明：
#   * 在 VS Code 中运行（Ctrl+F5 / Syslab: 运行当前脚本）时，图形显示在 Syslab 的图窗中；
#   * 保存图片请用 exportgraphics / plt_print / saveas，注意 savefig 只支持 .syslabfig；
#   * gtext、zoom 等交互式函数需要 Syslab 图形界面，纯脚本运行会报错。
# -----------------------------------------------------------------------------

using TyPlot

x = range(0, 2pi; length = 200)
y = sin.(x)

figure()
plot(x, y, "b-"; linewidth = 2)
title("Syslab x VS Code - sin(x)")
xlabel("x / rad")
ylabel("sin(x)")
grid("on")

ax = gca()
outfile = joinpath(@__DIR__, "sin_wave.jpg")
exportgraphics(ax, outfile)
println("图已保存到：", outfile)
println("SYSLAB_PLOT_OK")
