using TyPlot
using TyBase

ax1 = subplot(2, 2, 1) 

t = 0:pi/50:5*pi
y = exp.(-t / 2.5) .* sin.(3t)

plot(ax1, t, y, "-b"; linewidth = 2)  
hold(ax1, "on")  
plot(ax1, t, zeros(size(t)), "k-")
hold(ax1, "off")

axis(ax1, [0 5*pi -1 1])
xlabel(ax1, "t/s")
ylabel(ax1, "y")
title(ax1, "y-t curve")
text(ax1, 6.77, 0.12, raw"$\leftarrow dy/dx=0$")
gtext("myplot") 
ax2 = subplot(2, 2, 2; projection = "3d") 

t2 = 0:pi/50:10*pi
x2 = sin.(t2)
y2 = cos.(t2)
plot3(ax2, x2, y2, t2)
title(ax2, "三维螺旋线")

x = -5:0.2:5
y = x
X, Y = meshgrid2(x, y)
Z = X .^ 2 .+ Y .^ 2

ax3 = subplot(2, 2, 3; projection = "3d")
s1 = surf(ax3, X, Y, Z)
title(ax3, "figure 1: surf")

ax4 = subplot(2, 2, 4; projection = "3d")
s2 = surf(ax4, X, Y, Z)
shading(s2, "flat") 
title(ax4, "figure 2: surf with flat")
