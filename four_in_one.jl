# ============================================================
#  四张图放进同一个 figure（2×2 子图布局）
#  使用 Syslab 自带的 TyPlot（MATLAB 兼容绘图库，与原代码语法一致）
#  关键改动：每张图前用 subplot(2,2,k) 指定位置，3D 图要加 projection="3d"
# ============================================================
using TyPlot
using TyBase

# ------------------------------------------------------------
# 子图 1：y-t 曲线
# ------------------------------------------------------------
ax1 = subplot(2, 2, 1)                  # ← 放进同一个 figure 的第 1 格

t = 0:pi/50:5*pi
y = exp.(-t / 2.5) .* sin.(3t)

plot(ax1, t, y, "-b"; linewidth = 2)    # 实线、蓝色、线宽 2
hold(ax1, "on")                         # 叠加 0 参考线
plot(ax1, t, zeros(size(t)), "k-")
hold(ax1, "off")

axis(ax1, [0 5*pi -1 1])                # x 轴 [0,5π]，y 轴 [-1,1]
xlabel(ax1, "t/s")
ylabel(ax1, "y")
title(ax1, "y-t curve")
text(ax1, 6.77, 0.12, raw"$\leftarrow dy/dx=0$")   # 在 (6.77,0.12) 处标注
gtext("myplot")                         # 鼠标点选位置插入文本（交互式）

# ------------------------------------------------------------
# 子图 2：三维螺旋线
# ------------------------------------------------------------
ax2 = subplot(2, 2, 2; projection = "3d")   # 3D 子图必须指定 projection

t2 = 0:pi/50:10*pi
x2 = sin.(t2)
y2 = cos.(t2)
plot3(ax2, x2, y2, t2)
title(ax2, "三维螺旋线")

# ------------------------------------------------------------
# 子图 3 / 子图 4：曲面 z = x² + y²
# ------------------------------------------------------------
x = -5:0.2:5
y = x
X, Y = meshgrid2(x, y)                  # 生成坐标（Syslab 提供 meshgrid2）
Z = X .^ 2 .+ Y .^ 2                    # 表达式点运算

# 子图 3：普通绘制
ax3 = subplot(2, 2, 3; projection = "3d")
s1 = surf(ax3, X, Y, Z)
title(ax3, "figure 1: surf")

# 子图 4：平面着色（flat）
ax4 = subplot(2, 2, 4; projection = "3d")
s2 = surf(ax4, X, Y, Z)
shading(s2, "flat")                     # 等价于原 s.set_edgecolor("flat")
title(ax4, "figure 2: surf with flat")

# 整个 figure 的总标题（可选）
sgtitle("四图合一：y-t curve / 三维螺旋线 / surf / surf-flat")
