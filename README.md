# VScodeWithSyslab

> 项目名 / 仓库名：**VScodeWithSyslab** ｜ 扩展 ID：`StKGC.syslab-bridge`（安装后显示为 `stkgc.syslab-bridge`）
> 仓库：https://github.com/BlackTea-Lee/VScodeWithSyslab （私有）

让 **MWORKS.Syslab** 的编辑器与脚本运行能力在**原生 VS Code** 里可用：
用 VS Code 打开/编辑 `.jl`、`.m/.tym` 文件，直接调用 Syslab 自带的 Julia 运行时与全部
Syslab 包（TyBase / TyMath / TyPlot …），运行脚本、启动 REPL、调试、语言服务、绘图面板。

> 本工具包**不修改 Syslab 安装目录**，只在 VS Code 侧安装扩展、写入环境变量与设置。

**本机实测结果**（VS Code 1.137/1.138 + MWORKS.Syslab 2026b 26.6.1）：

```
TongYuan.syslab-julia     installed=true  active=true
TongYuan.julia-analyzer   installed=true  active=true
TongYuan.tymlang-ide      installed=true  active=true
TongYuan.app-designer     installed=true  active=true
julia 进程                由 Code.exe 启动（Syslab REPL / 语言服务）
```

---

## 一、原理

Syslab 本身是一个 VS Code（Code-OSS）分支，编辑器能力来自这几个扩展：

| 扩展 | 作用 |
| --- | --- |
| `TongYuan.syslab-julia` | Julia 语言支持：运行/调试脚本、REPL、工作区变量、绘图面板、代码块执行…（julia-vscode 的 Syslab 定制版） |
| `TongYuan.julia-analyzer` | Julia 静态分析与语言服务（julia-analyzer 二进制） |
| `TongYuan.tymlang-ide` | M 语言（TyMLang，`.m` / `.tym`）编辑、运行与调试 |
| `TongYuan.app-designer` | Syslab APP Designer |

这些扩展运行时依赖一组环境变量，由 Syslab 主程序在 `out/syslab-environment-win32.js` 注入：

```
SYSLAB_HOME         Syslab 安装目录
TONGYUAN_PATH       共享数据目录（C:/Users/Public/TongYuan）
JULIA_HOME          Syslab 自带 Julia（julia-1.10.10）
JULIA_DEPOT_PATH    Julia Depot（.julia，含 TyBase/TyMath/TyPlot 等 600+ 包）
SYSLAB_JULIA_PATH   syslab-julia
PATH / PYTHON / KMP_DUPLICATE_LIB_OK / JULIA_USE_FLISP_PARSER ...
```

本工具包做四件事：

1. **复刻这套环境变量**（`bin/syslab-env.ps1` 与 Syslab 主程序逐项对齐），生成
   `%USERPROFILE%\.syslab-vscode\env.json`，并写入 VS Code 的
   `terminal.integrated.env.windows` 与终端配置文件 `Syslab Julia`；
2. 把 Syslab 自带扩展**打包成 VSIX，用 `code --install-extension` 正式安装**
   （VS Code 1.7x 起不再识别手工拷贝到 `~/.vscode/extensions` 的扩展目录）；
3. 打**兼容性补丁**（见第五节），修掉 Syslab 扩展在原生 VS Code 里的两处硬冲突；
4. 附带桥接扩展 `syslab-bridge`，提供 `运行当前脚本`、`Syslab REPL`、`运行选中代码`、
   `环境自检`、`用 Syslab 打开` 等命令，并补齐 Syslab 外壳专有命令占位。

---

## 二、快速开始

```powershell
# 1) 安装（自动探测 Syslab 与 VS Code；-IncludeCopilot 可一并装 MWORKS Copilot）
powershell -ExecutionPolicy Bypass -File install.ps1

# 2) 自检（会实际加载 TyBase/TyMath/TyPlot，第一次可能较慢）
powershell -ExecutionPolicy Bypass -File scripts\Test-SyslabEnv.ps1

# 3) 用带 Syslab 环境的 VS Code 打开工程
bin\Syslab-Code.cmd "D:\你的工程目录"
```

在 VS Code 中：

* 打开 `.jl` 文件 → `Ctrl+F5`（`Syslab: 运行当前脚本`），或命令面板
  `Syslab: 在 REPL 中运行当前脚本` / `Syslab: 启动 Julia REPL`；
* 左侧活动栏出现 **Syslab Julia**（工作区变量 / REPL 历史）、**包管理器**、**Application**、
  **MLang 工作区** 等视图；
* 终端下拉里多出 **Syslab Julia** 配置文件，任何终端都带 Syslab 环境；
* 状态栏显示 `Syslab julia-1.10.10`，点击查看环境详情。

> 直接启动 VS Code 也可以（`terminal.integrated.env.windows` 已注入环境）；
> `Syslab-Code.cmd` 会让**整个 VS Code 进程**（含扩展宿主）都拿到 Syslab 环境，与
> Syslab 主程序的启动方式完全一致，最稳妥。

---

## 三、目录结构

```
MWORKS\
├─ install.ps1                  一键安装（环境文件 + VSIX 扩展 + 兼容补丁 + VS Code 设置）
├─ install.sh                   Linux / macOS 版一键安装（环境 + 扩展 + 设置）
├─ uninstall.ps1                卸载（-RestoreSettings 可还原备份的设置）
├─ bin\
│   ├─ syslab-env.ps1           解析 Syslab 安装位置与环境变量（可 dot-source）
│   ├─ vscode-kit.ps1           VS Code 定位 / VSIX 安装 / 兼容补丁 / JSONC 读写 / 扩展缓存修复
│   ├─ Syslab-Code.cmd          以 Syslab 完整环境启动 VS Code（推荐入口）
│   ├─ Start-SyslabCode.ps1     同上（PowerShell 实现）
│   ├─ Syslab-Shell.cmd         打开带 Syslab 环境的 Julia REPL
│   └─ Start-SyslabShell.ps1    同上（PowerShell 实现）
├─ extension\                   桥接扩展源码（StKGC.syslab-bridge，publisher 可在 package.json 里改）
├─ scripts\
│   ├─ Build-SyslabVsix.ps1     把 Syslab 扩展打包为 VSIX（-Install 可直接安装）
│   ├─ New-SyslabVsix.ps1       单个扩展目录 → VSIX（自动应用兼容补丁）
│   ├─ Pack-ExtensionRelease.ps1 生成「可上云」发布包（VSIX + manifest.json + SHA256SUMS）
│   ├─ Install-ExtensionPack.ps1 从云端/本地发布包安装（下载 + 校验 + 安装 + 写环境）
│   ├─ Publish-Marketplace.ps1   把桥接扩展上架 VS Code Marketplace（vsce + PAT）
│   ├─ Test-SyslabEnv.ps1       环境自检
│   ├─ Run-SyslabScript.ps1     命令行运行 .jl 脚本（批处理/CI 可用）
│   └─ check-syntax.js          开发辅助：校验扩展 JS/JSON 语法
├─ samples\
│   ├─ quick_start.jl           环境验证示例（TyBase/TyMath，不绘图）
│   ├─ plot_demo.jl             TyPlot 绘图 + exportgraphics 导出图片
│   └─ demo.m                    M 语言示例
├─ vsix\                        本机构建缓存（已 gitignore）
├─ release\                     发布包（VSIX + manifest.json + SHA256SUMS，随仓库一起推送）
├─ cloud\PUBLISH.md             上云与多平台同步指南（GitHub / 对象存储 / 内网 / 市场）
└─ .gitignore                   仓库策略：release 入库、vsix/zip 不入库
```

生成的运行时文件：

| 文件 | 说明 |
| --- | --- |
| `%USERPROFILE%\.syslab-vscode\env.json` | 与 Syslab 主程序一致的环境变量（桥接扩展读取） |
| `%USERPROFILE%\.syslab-vscode\env.cmd` / `env.ps1` | 同样的环境变量，供批处理/PowerShell 使用 |
| `%USERPROFILE%\.syslab-vscode\bridge-status.json` | 启动自检结果：Syslab 扩展是否安装/激活成功（排查用） |

---

## 四、命令一览（桥接扩展）

| 命令 | 说明 |
| --- | --- |
| `Syslab: 运行当前脚本（新进程）` | 用 Syslab 的 Julia + 默认环境运行当前文件（`Ctrl+F5`） |
| `Syslab: 在 REPL 中运行当前脚本` | 在 Syslab REPL 里 `include(...)` |
| `Syslab: 运行选中代码` | 选中片段送入 REPL |
| `Syslab: 启动 / 关闭 Julia REPL` | 启动 `julia --project=…\environments\v1.10 -i`，默认预加载 TyBase/TyMath/TyPlot |
| `Syslab: 用 MWORKS Syslab 打开当前文件` | 交给 Syslab 主程序打开 |
| `Syslab: 环境自检` | 在新终端里打印 Julia 版本/环境并加载预置包 |
| `Syslab: 显示环境信息` | 输出通道里列出全部环境变量与关键文件检查 |
| `Syslab: 打开 Depot / 安装目录` | 资源管理器中定位 |

`.m` / `.tym` 由 Syslab 的 TyMLangIDE 扩展执行（`tymlang.executeFileByUrl` / `language-julia.executeActiveFile`），
桥接扩展负责在命令不可用时给出明确提示。

---

## 五、兼容性补丁（为什么需要，做了什么）

Syslab 扩展是按 Syslab 自己的外壳写的，直接搬到原生 VS Code 会遇到两类硬冲突，
**不处理会导致扩展激活失败（表现为“装了但没反应”）**。工具包在打包 VSIX 时自动打补丁
（只作用于 VSIX 里的副本与已安装副本，不改 Syslab 安装目录）：

1. **命令名冲突**
   `tongyuan.syslab-julia` 在 activate 阶段注册通用命令名 `extension.refreshTreeView`，
   而第三方扩展（本机是 `mermaidchart.vscode-mermaid-chart`）也注册了同名命令，
   VS Code 对重复注册直接抛异常：
   `Error: command 'extension.refreshTreeView' already exists` → 整个扩展激活失败。
   补丁把该命令改名为 `syslab.extension.refreshTreeView`（同时改 `package.json` 的菜单引用）。

2. **缺少 Syslab 外壳命令**
   Syslab 扩展会调用一批由 Syslab 主程序提供的命令，例如
   `vscode.handleSyslabExtensionFinished`、`syslab.getWorkPathDefault`、`Syslab.getProductInfo` 等。
   原生 VS Code 没有这些命令，`await executeCommand(...)` 失败会中断激活。
   桥接扩展在启动时（`activationEvents: ["*"]`，先于 `onLanguage:julia`）为
   **“既没有被任何已装扩展贡献、也尚未注册”** 的 Syslab 外壳命令注册空实现（本机 78 个），
   保证 Syslab 扩展能完整激活；对应的高级功能自然降级，编辑/运行/调试/REPL 主流程不受影响。

补丁是幂等的：已改名的文件再次打包会提示“复用已有 VSIX”，不会重复改名。

---

## 六、常见问题

**1. VS Code 里看不到 Syslab 扩展？**
先看 `%USERPROFILE%\.syslab-vscode\bridge-status.json`：

* `installed:false` → 扩展没装上，重新运行 `install.ps1`（**建议先关闭 VS Code**）；
* `installed:true, active:false` → 打开一个 `.jl`（或 `.m`）文件后会自动激活；
* 扩展列表里显示“已禁用/不兼容” → 在扩展面板中启用，或确认 `engines.vscode` 与你的 VS Code 匹配。

**2. 安装时报 “Please restart VS Code before reinstalling …”**
正在运行的 VS Code 占用扩展文件。关掉 VS Code 再跑一次 `install.ps1` 即可；
安装脚本会先清理“目录存在但没有 package.json”的残缺安装，并修复 `extensions.json` 里的失效记录。

**3. 一定要用 `Syslab-Code.cmd` 启动吗？**
不是必须。`install.ps1` 已把 Syslab 环境写进 `terminal.integrated.env.windows`，
直接启动 VS Code 时终端也有 Syslab 环境；`Syslab-Code.cmd` 只是让整个 VS Code 进程都拿到环境。

**4. 首次加载包很慢？**
TyBase/TyMath/TyPlot 首次加载需要预编译（本机约 10 秒，冷启动可能更久），之后走
`JULIA_DEPOT_PATH/compiled` 缓存。

**5. `.m` 文件被 MATLAB 扩展抢走？**
`.m` 同时被 `mathworks.language-matlab` 与 `tongyuan.tymlang-ide` 声明。可在 VS Code
右下角语言模式里选择 *M*，或写工作区设置：

```jsonc
"files.associations": { "*.m": "mlang" }
```

**6. 与 Syslab 自带的编辑器相比少了什么？**
MWORKS Copilot（需 Syslab 账号与服务器）、Syslab 应用市场、帮助浏览器、登录态属于
Syslab 主程序的专有能力；其余编辑/运行/调试/绘图/工作区变量/包管理等功能已随扩展带过来。

**7. 绘图脚本报 PyError / `gtext` 之类交互函数报错？**
`savefig` 在当前 TyPlot 版本里只接受 `.syslabfig`，导出普通图片请用
`exportgraphics(ax, "x.jpg")` / `plt_print()` / `saveas(gcf, "x.png")`（见 `samples\plot_demo.jl`，
已验证可离屏导出 JPEG）。
`gtext`、`zoom` 等**交互式**函数需要 Syslab 的图形界面，纯脚本/终端运行时必然失败，
请改用非交互接口，或在 MWORKS Syslab 主程序里运行该脚本。

**8. 如何卸载？**

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1                     # 清理扩展与设置键
powershell -ExecutionPolicy Bypass -File uninstall.ps1 -RestoreSettings    # 还原 install 前的 settings.json
```

---

## 七、在其它机器上离线安装

`vsix\` 目录里的包可以直接拷走（`TongYuan.syslab-julia` 约 38 MB、`TongYuan.app-designer` 约 29 MB）：

```powershell
code --install-extension vsix\TongYuan.syslab-julia-26.1.0.vsix --force
code --install-extension vsix\TongYuan.julia-analyzer-26.4.0.vsix --force
code --install-extension vsix\TongYuan.tymlang-ide-26.1.0.vsix --force
code --install-extension vsix\TongYuan.app-designer-26.1.0.vsix --force
code --install-extension vsix\StKGC.syslab-bridge-1.0.0.vsix --force
```

目标机器仍需安装 MWORKS.Syslab（提供 Julia 运行时与包），再运行一次 `install.ps1`
写入环境变量与设置即可。

---

## 八、上云下载与多平台同步

**一句话方案**：`Pack-ExtensionRelease.ps1` 生成发布包 → 上传到 GitHub Release / 对象存储 / 内网 HTTP
→ 其它机器用 `Install-ExtensionPack.ps1`（Windows）或 `install.sh`（Linux/macOS）一条命令拉取安装。
完整指南（含合规说明与市场发布步骤）见 **`cloud\PUBLISH.md`**。

```powershell
# ① 生成本机发布包（含 manifest.json + SHA256SUMS.txt，可 -Zip 打成单个 zip）
powershell -ExecutionPolicy Bypass -File scripts\Pack-ExtensionRelease.ps1 -PackVersion 2026.0916 -Zip

# ② 分发（二选一）
#    2a) 用 GitHub 仓库当下载源：把 release\ 一起提交推送（.gitignore 已保留 release\）
#        其它机器直接指 raw 链接即可：
#        -Source https://github.com/<你>/<仓库>/raw/main/release/manifest.json
#    2b) 用 GitHub Release / 对象存储 / nginx / 网盘：上传 release\ 目录或那个 zip

# ③ 其它机器（Windows）：下载 + 校验 + 安装 + 写环境，一步到位
powershell -ExecutionPolicy Bypass -File scripts\Install-ExtensionPack.ps1 -Source https://<你的地址>/syslab-pack/
#    只装桥接扩展：加 -OnlyBridge

# ③ 其它机器（Linux / macOS）
./install.sh --base-url https://<你的地址>/syslab-pack/

# ④ 私有 GitHub 仓库（匿名 raw 会 404）：克隆后用本地目录安装，凭据交给 git 即可
git clone https://github.com/<你>/<仓库>.git
scripts\Install-ExtensionPack.ps1 -Source .\<仓库>\release        # Linux/macOS: ./install.sh --vsix-dir ./<仓库>/release
```

> 本仓库已推到 `https://github.com/BlackTea-Lee/VScodeWithSyslab`（项目名 / 仓库名：**VScodeWithSyslab**），
> `release/` 随仓库一起提交；该仓库目前是**私有**的，所以其它机器请用上面的「克隆 + 本地目录」方式，
> 或在 GitHub 上把仓库改成 Public 后直接用 raw 链接。

**把桥接扩展上架市场（可选，上架后扩展面板可搜索 + Settings Sync 自动同步）**：

```powershell
# 一次性：装 Node.js LTS、在 dev.azure.com 生成 PAT（权限 Marketplace > Manage）、
#         在 marketplace.visualstudio.com/manage 建同名 publisher（当前为 StKGC）
$env:VSCE_PAT = '<你的PAT>'
powershell -ExecutionPolicy Bypass -File scripts\Publish-Marketplace.ps1
# 想先只打包检查：加 -PackageOnly
```

实测（本机用一个本地 HTTP 服务模拟云端）：

```
=== 1/4 获取扩展发布包 ===  下载 manifest.json / 下载 StKGC.syslab-bridge-1.0.0.vsix
=== 2/4 校验扩展包 ===      syslab-vscode-pack 2026.0916 · 源自 MWORKS.Syslab 2026b / Julia 1.10.10 · SHA256 校验通过
=== 3/4 安装到 VS Code ===  已安装 StKGC.syslab-bridge-1.0.0.vsix
=== 完成：成功安装 1 / 1 个扩展 ===
```

**关于 VS Code 多平台同步（Settings Sync）的关键事实**：

* Settings Sync 同步的是**扩展清单**，新机器从**扩展市场**重新下载 —— 私有 VSIX 不会被同步；
* 所以：`syslab-bridge` 可以上架市场（MIT，允许），上架后打开同步即自动装好，跨平台开箱可用；
* 同元软控的 4 个扩展**不要公开上架**，用发布包 + 引导脚本（开机任务 / Intune / Ansible）兜底；
* 目标平台仍需各自安装 MWORKS.Syslab 并运行 `install.ps1` / `install.sh` 生成环境变量
  （Linux/macOS 的 Julia 路径、Depot、`LD_LIBRARY_PATH` 与 Windows 不同，脚本已按 Syslab 的
  `out/syslab-environment-linux.js` 复刻）。

---

## 九、实测记录

```
> powershell -File scripts\Run-SyslabScript.ps1 samples\quick_start.jl
Julia 版本   : 1.10.10+12
活跃环境     : C:\Users\Public\TongYuan\.julia\environments\v1.10\Project.toml
Depot        : C:/Users/Public/TongYuan/.julia
Syslab 版本  : 26.6.1
sin(pi/2)    : 1.0
det(a)       : -2.0
SYSLAB_SCRIPT_OK

> powershell -File scripts\Run-SyslabScript.ps1 samples\plot_demo.jl
图已保存到：...\samples\sin_wave.jpg
SYSLAB_PLOT_OK

> powershell -File scripts\Test-SyslabEnv.ps1
 [通过] Syslab 安装与 Julia 运行时
 [通过] 环境变量注入
 [通过] julia --version
 [通过] Syslab 默认环境（Julia 包）        # packages OK，耗时 8.6 秒
 [通过] 在 Syslab 环境中运行脚本（新进程）  # TyPlot 导出图片 OK / SYSLAB_SCRIPT_OK
 [通过] VS Code 扩展安装情况
 全部检查通过：Syslab 环境可直接在 VS Code 中使用 ✓
```

VS Code 端（`%USERPROFILE%\.syslab-vscode\bridge-status.json`，打开 `.jl` / `.m` 后自动写入）：

```json
{
  "vscodeVersion": "1.138.0",
  "envSource": "C:\\Users\\29136\\.syslab-vscode\\env.json",
  "juliaAvailable": true,
  "syslabExtensions": {
    "TongYuan.syslab-julia":   { "installed": true, "active": true },
    "TongYuan.julia-analyzer": { "installed": true, "active": true },
    "TongYuan.tymlang-ide":    { "installed": true, "active": true },
    "TongYuan.app-designer":   { "installed": true, "active": true }
  },
  "shellStubs": 78
}
```
