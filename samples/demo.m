% -----------------------------------------------------------------------------
% MWORKS Syslab M 语言（TyMLang）示例
% 在 VS Code 中使用：需安装 Syslab 的 TyMLangIDE 扩展（install.ps1 已包含）
% -----------------------------------------------------------------------------

x = 0:0.05:2*pi;
y = sin(x) + 0.2*cos(3*x);

disp('MWORKS M 语言脚本运行成功');
disp(['数组长度: ', num2str(length(x))]);
disp(['最大值  : ', num2str(max(y))]);

figure;
plot(x, y);
title('Syslab M 语言示例');
xlabel('x');
ylabel('sin(x)+0.2cos(3x)');
grid on;
