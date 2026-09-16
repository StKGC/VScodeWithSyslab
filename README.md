# VScodeWithSyslab

> 项目名 / 仓库名：**VScodeWithSyslab** ｜ 扩展 ID：`StKGC.vscodewithsyslab`（安装后显示为 `stkgc.vscodewithsyslab`）
> 仓库：https://github.com/StKGC/VScodeWithSyslab （私有）

让 **MWORKS.Syslab** 的编辑器与脚本运行能力在**原生 VS Code** 里可用：
用 VS Code 打开/编辑 `.jl`、`.m/.tym` 文件，直接调用 Syslab 自带的 Julia 运行时与全部
Syslab 包（TyBase / TyMath / TyPlot …），运行脚本、启动 REPL、调试、语言服务、绘图面板。

> 本工具包**不修改 Syslab 安装目录**，只在 VS Code 侧安装扩展、写入环境变量与设置。

**本机实测结果**（VS Code 1.137/1.138 + MWORKS.Syslab 2026b 26.6.1）：

```
StKGC.syslab-julia     installed=true  active=true
StKGC.julia-analyzer   installed=true  active=true
StKGC.tymlang-ide      installed=true  active=true
StKGC.app-designer     installed=true  active=true
julia 进程                由 Code.exe 启动（Syslab REPL / 语言服务）
```

---

## 一、原理

Syslab 本身是一个 VS Code（Code-OSS）分支，编辑器能力来自这几个扩展：

| 扩展 | 作用 |
| --- | --- |
| `StKGC.syslab-julia` | Julia 语言支持：运行/调试脚本、REPL、工作区变量、绘图面板、代码块执行…（julia-vscode 的 Syslab 定制版） |
| `StKGC.julia-analyzer` | Julia 静态分析与语言服务（julia-analyzer 二进制） |
| `StKGC.tymlang-ide` | M 语言（TyMLang，`.m` / `.tym`）编辑、运行与调试 |
| `StKGC.app-designer` | Syslab APP Designer |

> **发布者前缀说明（重要）**：打包时会把四个 Syslab 扩展的发布者前缀**统一改写为 `StKGC`**
> （整合前是 `TongYuan.*`），让整套扩展落在同一命名空间、便于统一安装/卸载/分发。
> 改写**只作用于打进 VSIX 的副本**（含 `package.json`、`extensionDependencies`、以及 JS 产物里
> 硬编码的扩展 ID），**不动 MWORKS.Syslab 安装目录**（源目录仍是 `tongyuan.*`）。
> 扩展的**著作权与许可仍归同元软控**，本改写仅用于自有环境的私有分发，**请勿公开上架 VS Code Marketplace**。
> 想恢复原始前缀：`Build-SyslabVsix.ps1 -Publisher TongYuan`（或直接改 `extension\package.json` 的 `publisher`）。

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
4. 附带桥接扩展 `vscodewithsyslab`，提供 `运行当前脚本`、`Syslab REPL`、`运行选中代码`、
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
VScodeWithSyslab\
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
├─ extension\                   桥接扩展源码（StKGC.vscodewithsyslab，publisher 可在 package.json 里改）
│   └─ lib\                     纯逻辑模块：packages.js（读环境包列表）、completion.js（补全检索）
├─ scripts\
│   ├─ Build-SyslabVsix.ps1     把 Syslab 扩展打包为 VSIX（-Install 可直接安装）
│   ├─ New-SyslabVsix.ps1       单个扩展目录 → VSIX（自动应用兼容补丁）
│   ├─ Pack-ExtensionRelease.ps1 生成「可上云」发布包（VSIX + manifest.json + SHA256SUMS）
│   ├─ Install-ExtensionPack.ps1 从云端/本地发布包安装（下载 + 校验 + 安装 + 写环境）
│   ├─ Publish-Marketplace.ps1   把桥接扩展上架 VS Code Marketplace（vsce + PAT）
│   ├─ Push-ViaGitHubApi.ps1     git push 被网络阻断时，改用 GitHub API 推送（SHA 与本地一致，不分叉）
│   ├─ Update-PreloadEnum.ps1    按当前环境刷新「预加载包」设置页的下拉候选（enum）
│   ├─ update-preload-enum.js    上者的 Node 实现（安全改写已安装扩展的 package.json）
│   ├─ Set-LintMode.ps1          调整 Julia 静态检查严格度（quiet/balanced/strict）
│   ├─ Build-CompletionIndex.ps1 生成离线代码补全索引（+ build-completion-index.jl）
│   ├─ Test-CompletionIndex.ps1  自检补全索引（+ test-completion-index.js，断言检索逻辑）
│   ├─ Test-SyslabEnv.ps1       环境自检
│   ├─ Run-SyslabScript.ps1     命令行运行 .jl 脚本（批处理/CI 可用）
│   └─ check-syntax.js          开发辅助：校验扩展 JS/JSON 语法
├─ samples\
│   ├─ quick_start.jl           环境验证示例（TyBase/TyMath，不绘图）
│   ├─ plot_demo.jl             TyPlot 绘图 + exportgraphics 导出图片
│   └─ demo.m                    M 语言示例
├─ vsix\                        本机构建缓存（已 gitignore）
├─ release\                     发布包（VSIX + manifest.json + SHA256SUMS）；**本地构建产物，已 gitignore**，
│                               对外分发走 GitHub Releases 附件（`Pack-ExtensionRelease.ps1 -PublishGitHub`）
├─ cloud\PUBLISH.md             上云与多平台同步指南（GitHub / 对象存储 / 内网 / 市场）
└─ .gitignore                   仓库策略：release/ 与 vsix/、*.zip 不入库（走 GitHub Releases）
```

生成的运行时文件：

| 文件 | 说明 |
| --- | --- |
| `%USERPROFILE%\.syslab-vscode\env.json` | 与 Syslab 主程序一致的环境变量（桥接扩展读取） |
| `%USERPROFILE%\.syslab-vscode\env.cmd` / `env.ps1` | 同样的环境变量，供批处理/PowerShell 使用 |
| `%USERPROFILE%\.syslab-vscode\bridge-status.json` | 启动自检结果：Syslab 扩展是否安装/激活成功（排查用） |
| `%USERPROFILE%\.syslab-vscode\completion.json` | 离线代码补全索引（`Build-CompletionIndex.ps1` 生成，见第十节） |

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
| `Syslab: 选择预加载包…（多选）` | **图形化勾选** REPL/终端启动时预加载的包（选项来自当前环境的真实包列表），自动同步三处设置 |
| `Syslab: 生成代码补全索引` | 用 Syslab 的 Julia 导出常用包的符号+文档，生成离线补全索引 |
| `Syslab: 重新载入代码补全索引` | 输出当前索引的条目数/包列表（索引按 mtime 自动感知更新） |
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
   `StKGC.syslab-julia` 在 activate 阶段注册通用命令名 `extension.refreshTreeView`，
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

**4′. 编辑器报 `xxx(MissingRef)` / “未定义的全局变量”，是环境坏了吗？**
不是。纯 VS Code 里有两套静态检查在工作，它们**只做静态推断**，看不到运行时的动态绑定：

| 诊断来源 | 例子 | 由谁控制 |
| --- | --- | --- |
| `StKGC.syslab-julia` 自带 linter（julia-vscode / StaticLint 血统） | `figureJulia(MissingRef)`、未定义引用 | `julia.lint.*`（`julia.lint.run`、`julia.lint.missingrefs`） |
| `StKGC.julia-analyzer`（独立二进制） | “未定义的全局变量 'VERSION'”、“类型不稳定” | `julia-analyzer.*` |

先分清两种情况：

1. **符号确实不存在** → 改代码。例如本机 TyPlot 只有 `figure()`/`gcf()`，**没有** `figureJulia()`
   （在 TyPlot/TyBase/TyPlot2/TyPlotCore/TyMathPlot 与 Syslab 安装目录里都搜不到这个名字）；
2. **符号存在但静态检查看不到**（宏生成、`include` 到别处的函数、动态加载的包、只有运行时才绑定的名字）
   → 用档位脚本收敛噪音：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\Set-LintMode.ps1 -Show            # 看当前设置
powershell -ExecutionPolicy Bypass -File scripts\Set-LintMode.ps1 -Mode balanced   # 推荐：关掉误报较多的“类型不稳定/类型检查”
powershell -ExecutionPolicy Bypass -File scripts\Set-LintMode.ps1 -Mode quiet      # 关掉两套 linter 的未定义引用检查
powershell -ExecutionPolicy Bypass -File scripts\Set-LintMode.ps1 -Mode strict     # 全开（missingrefs=all + 类型检查）
```

改完在 VS Code 里 `Developer: Reload Window` 生效（或直接改设置：`julia.lint.missingrefs` 设为
`none` 只关这一类检查）。

**5. `.m` 文件被 MATLAB 扩展抢走？**
`.m` 同时被 `mathworks.language-matlab` 与 `StKGC.tymlang-ide` 声明。可在 VS Code
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

`vsix\` 目录里的包可以直接拷走（`StKGC.syslab-julia` 约 38 MB、`StKGC.app-designer` 约 29 MB）：

```powershell
code --install-extension vsix\StKGC.syslab-julia-26.1.0.vsix --force
code --install-extension vsix\StKGC.julia-analyzer-26.4.0.vsix --force
code --install-extension vsix\StKGC.tymlang-ide-26.1.0.vsix --force
code --install-extension vsix\StKGC.app-designer-26.1.0.vsix --force
code --install-extension vsix\StKGC.vscodewithsyslab-1.2.0.vsix --force
```

目标机器仍需安装 MWORKS.Syslab（提供 Julia 运行时与包），再运行一次 `install.ps1`
写入环境变量与设置即可。

---

## 八、上云下载与多平台同步

**分发模型**：`release/`（VSIX + manifest.json + SHA256SUMS）只是**本机构建产物**，已加入 `.gitignore`；
发布时用 `Pack-ExtensionRelease.ps1 -PublishGitHub` 一把「打包 → 上传为 GitHub Release 附件」，
其它机器用 `-GitHubRelease <owner/repo>@<tag>` 一条命令安装。
**仓库里只放源码与脚本，git 历史不会随每次发版变大。** 完整指南见 **`cloud\PUBLISH.md`**。

```powershell
# ① 打包 + 上传为 GitHub Release 附件（私有仓库自动使用 git 已保存的凭据）
powershell -ExecutionPolicy Bypass -File scripts\Pack-ExtensionRelease.ps1 `
    -PackVersion 1.2.0 -PublishGitHub StKGC/VScodeWithSyslab -Tag v1.2.0

# ② 其它机器安装（Windows）：下载 + SHA256 校验 + 安装 + 写环境，一步到位
powershell -ExecutionPolicy Bypass -File scripts\Install-ExtensionPack.ps1 `
    -GitHubRelease StKGC/VScodeWithSyslab@v1.2.0
#   私有仓库会自动取 git 凭据（也可显式 -Token / $env:GITHUB_TOKEN）；只装桥接扩展加 -OnlyBridge

# ② 其它机器安装（Linux / macOS）
./install.sh --github-release StKGC/VScodeWithSyslab@v1.2.0
```

其它分发方式（对象存储 / 内网 nginx / 网盘 / 仓库内 raw）与私有仓库注意事项见 `cloud\PUBLISH.md`；
`Install-ExtensionPack.ps1 -Source <目录|zip|基地址>` 与 `install.sh --base-url/--vsix-dir` 均保留。

实测（Release 附件下载 + 校验 + 安装，v1.0.0 首版记录）：

```
Release: https://github.com/StKGC/VScodeWithSyslab/releases/tag/v1.0.0
附件   : StKGC.syslab-julia-26.1.0.vsix / julia-analyzer / tymlang-ide / app-designer
         StKGC.vscodewithsyslab-1.0.0.vsix / manifest.json / SHA256SUMS.txt
安装   : 已下载 manifest.json → 下载 StKGC.vscodewithsyslab-1.0.0.vsix → SHA256 校验通过 → 已安装
```

**当前最新发布：`v1.2.0`**（含离线代码补全，见第十节）：
https://github.com/StKGC/VScodeWithSyslab/releases/tag/v1.2.0 —— 附件同样是 7 个
（4 个 `StKGC.*` 同元扩展 + `StKGC.vscodewithsyslab-1.2.0.vsix` + `manifest.json` + `SHA256SUMS.txt`）。

**把桥接扩展上架市场（可选，上架后扩展面板可搜索 + Settings Sync 自动同步）**：

```powershell
# 一次性：装 Node.js LTS、在 dev.azure.com 生成 PAT（权限 Marketplace > Manage）、
#         在 marketplace.visualstudio.com/manage 建同名 publisher（当前为 StKGC）
$env:VSCE_PAT = '<你的PAT>'
powershell -ExecutionPolicy Bypass -File scripts\Publish-Marketplace.ps1
# 想先只打包检查：加 -PackageOnly
```

**关于 VS Code 多平台同步（Settings Sync）的关键事实**：

* Settings Sync 同步的是**扩展清单**，新机器从**扩展市场**重新下载 —— 私有 VSIX 不会被同步；
* 所以：`vscodewithsyslab` 可以上架市场（MIT，允许），上架后打开同步即自动装好，跨平台开箱可用；
* 同元软控的 4 个扩展**不要公开上架**，用发布包 + 引导脚本（开机任务 / Intune / Ansible）兜底；
* 目标平台仍需各自安装 MWORKS.Syslab 并运行 `install.ps1` / `install.sh` 生成环境变量
  （Linux/macOS 的 Julia 路径、Depot、`LD_LIBRARY_PATH` 与 Windows 不同，脚本已按 Syslab 的
  `out/syslab-environment-linux.js` 复刻）。

---

## 九、新增预加载库（REPL/终端启动时自动 `using`）

“预加载”就是**启动 REPL/终端时自动执行 `using A, B, C`**。它在三个层面各有一份配置，按下顺序操作即可。

### 做法 0（推荐，图形化勾选）：`Syslab: 选择预加载包…（多选）`

命令面板执行 **`Syslab: 选择预加载包…（多选）`**：

* 选项**来自当前 Syslab 默认环境的真实包列表**（读 `environments\v1.10\Project.toml` + `Manifest.toml`，
  本机实测 156 个，带版本号；末尾附 LinearAlgebra/Statistics 等常用标准库）；
* 已启用的包默认勾选，取消勾选即移除；
* 想加载列表之外的包，勾选第一项 **“$(edit) 手动输入其它包名…”** 再填名字（逗号分隔）；
* 确认后**一次性同步三处**：`syslab.preloadPackages`、`julia.syslab.preloadPkgs`、
  `terminal.integrated.profiles.*` 里 “Syslab Julia” 的 `-e "using …"`；
* 弹窗可直接点 **重启 Julia REPL** 或 **重新加载窗口** 让设置生效。

> 与 Syslab 设置页里可选的预加载包等价，但选项是**动态从环境里读出来的**，不会出现“填了不存在的包导致 REPL 起不来”。

### 做法 0′（不打开命令面板）：设置页的下拉候选

`设置 → 搜索 syslab.preloadPackages` 也可以选，下拉候选来自扩展清单里的 `items.enum`：

* 安装包内置 **42 个常用包**（Ty* 核心 + DataFrames/CSV/Revit 等生态常见包 + 常用标准库）；
* 运行 `install.ps1`（或单独执行 `scripts\Update-PreloadEnum.ps1`）后会**按本机环境刷新成完整候选**
  （本机实测 **42 → 156 个**，与默认环境 `[deps]` 一致），所以下拉里每一项都保证能在你的环境里 `using`；
* 用 `Pkg.add` 装了新包之后，再跑一次 `Update-PreloadEnum.ps1` 即可让它出现在下拉里；
* 下拉之外的自定义包：用上面的多选命令，或直接在 `settings.json` 里写（设置页会提示“不在候选列表中”，但能生效）。

### 第 1 步（必须）：把包装进 **Syslab 的默认环境**

预加载的包必须能在 Syslab 的活动环境（默认 `JULIA_DEPOT_PATH\environments\v1.10`）里被解析，
否则 REPL 启动就会报 `ArgumentError: Package xxx not found`。

```powershell
# 打开带 Syslab 环境的 Julia REPL
bin\Syslab-Shell.cmd
julia> using Pkg
julia> Pkg.add("MyPkg")                       # 从注册表安装
julia> Pkg.develop(path="D:\\my\\MyPkg.jl")   # 或装本地开发包（会写进同一个环境）
julia> using MyPkg                            # 验证能加载
```

也可以不改脚本、直接命令行验证（用我们注入的环境）：

```powershell
# 复制成 check.jl 内容是： using MyPkg
powershell -File scripts\Run-SyslabScript.ps1 .\check.jl
```

> Depot 是 `C:\Users\Public\TongYuan\.julia`；`Pkg.add` 默认装进环境 `@v1.10`（就是 Syslab 的默认环境）。
> 装到别的环境（例如项目环境）不会影响这里的预加载。

### 第 2 步：VS Code 侧配置（二选一）

**做法 A（推荐，一条命令写全三处）**：

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -SkipExtensions `
    -PreloadPackages TyBase,TyMath,TyPlot,MyPkg
```

它会同时写入：

| 设置 / 位置 | 作用 |
| --- | --- |
| `julia.syslab.preloadPkgs` | Syslab Julia 扩展启动 REPL 时加载 |
| `syslab.preloadPackages` | 桥接扩展：`Syslab Julia` 终端 profile、`Syslab: 环境自检` |
| `terminal.integrated.profiles.windows["Syslab Julia"].args` 的 `-e "using ..."` | 手动选该终端时加载 |

**做法 B（手工改设置）**：命令面板 → `Preferences: Open User Settings (JSON)`，加/改这三处：

```jsonc
{
  "julia.syslab.preloadPkgs": ["TyBase", "TyMath", "TyPlot", "MyPkg"],
  "syslab.preloadPackages":   ["TyBase", "TyMath", "TyPlot", "MyPkg"],
  "terminal.integrated.profiles.windows": {
    "Syslab Julia": {
      "path": "C:/Users/Public/TongYuan/julia-1.10.10/bin/julia.exe",
      "args": ["--project=C:/Users/Public/TongYuan/.julia/environments/v1.10",
               "-i", "--banner=no", "-e", "using TyBase, TyMath, TyPlot, MyPkg"],
      "icon": "beaker"
    }
  }
}
```

改完 `Developer: Reload Window` 生效；验证：命令面板 `Syslab: 环境自检`（会实际 `using` 一遍并打印结果）。

### 第 3 步：MWORKS Syslab 主程序侧（如果要让 Syslab IDE 也预加载）

Syslab 有自己的用户设置，与 VS Code 是两份：

```
%APPDATA%\Syslab\User\settings.json        # 加 "julia.syslab.preloadPkgs": ["TyBase","TyMath","TyPlot","MyPkg"]
```

### 可选：让**所有** Julia 会话（含脚本、批处理、CI）都预加载

在 depot 里放启动文件（对未加 `--startup-file=no` 的进程都生效）：

```julia
# C:\Users\Public\TongYuan\.julia\config\startup.jl
try
    using TyBase, TyMath, TyPlot, MyPkg
catch err
    @warn "预加载失败" exception = err      # 用 try/catch 避免一个包坏了整个 REPL 起不来
end
```

注意：启动会变慢（每个 Julia 进程都要加载）；出错会拖慢甚至中断会话，所以建议包 `try/catch`。
Syslab 的 REPL/调试器可能带 `--startup-file=no`，那种情况下以“第 2 步的设置”为准。

### 进阶：包多/包大时用自定义系统镜像

预加载越多，REPL 冷启动越慢。Syslab 支持把常用包编译进系统镜像：

* 设置 `julia.syslab.customSysimagePath` 指向镜像文件；
* 命令面板执行 `Syslab: Build System Image`（或 `Syslab: Edit Build Image Script` 先改脚本）再 `Syslab: Use New System Image`。

这样预加载几乎不花时间（镜像里已编译好），代价是打包/更新镜像需要几分钟。

---

## 十、代码自动补全（离线索引）

### 为什么不能直接用现成的语言服务器

原生 Julia 补全靠 `LanguageServer.jl`（也就是 `julia-vscode` 那一套）。Syslab 的 depot 里**只有**编辑器
（`StKGC.syslab-julia`）和诊断器（`StKGC.julia-analyzer`），没有语言服务器：

```
C:\Users\Public\TongYuan\.julia\packages\
    → 有 TyBase / TyMath / TyPlot / StaticLint …  没有 LanguageServer / JuliaWorkspaces
```

所以装完能看到语法高亮、能跑脚本，但**敲 `.` 不会弹补全**。自己装一个 `LanguageServer` 也可以，
但要联网拉包、要预编译，还容易和 Syslab 定制的 Julia / 环境版本打架。

本工具包的做法是 **离线快照 + 扩展内置补全器**：用 Syslab 自带的 Julia 把常用包的导出符号和一行文档
导出成 JSON，桥接扩展读这个 JSON 提供补全。零联网、零额外依赖、激活即可用。

### 生成索引

```powershell
# 按当前 syslab.preloadPackages（默认 TyBase/TyMath/TyPlot）生成
powershell -File scripts\Build-CompletionIndex.ps1

# 指定包（逗号分隔，覆盖默认列表）
powershell -File scripts\Build-CompletionIndex.ps1 -Packages TyBase,TyMath,TyPlot,TyStatistics

# 在默认列表外追加包；-NoDocs 不收集文档（更快、文件更小）
powershell -File scripts\Build-CompletionIndex.ps1 -ExtraPackages DataFrames,CSV -NoDocs

# 换输出位置
powershell -File scripts\Build-CompletionIndex.ps1 -Output D:\tmp\completion.json
```

脚本做三件事：

1. `Set-SyslabEnvironment` 注入 Syslab 的环境变量（**必须**；否则会去找系统默认 `~/.julia`，
   报 `Package TyMath … not installed`）；
2. 用 Syslab 的 Julia 跑 `scripts\build-completion-index.jl`：`using` 每个包 → 取
   `names(mod; all=false, imported=false)` 拿到导出符号 → 按值分类（function / type / const / module / value）
   → 用 `Base.Docs.doc` 取一行文档（压平空白、截断到 240 字符）；
3. 写 `%USERPROFILE%\.syslab-vscode\completion.json`。

`install.ps1` 会把它作为**第 4.8 步自动执行**一次（`-SkipCompletionIndex` 可跳过）。

实测（TyBase + TyMath + TyPlot，含文档）：

```
  TyBase: 371 个导出符号
  TyMath: 890 个导出符号
  TyPlot: 237 个导出符号
索引已写入：C:\Users\29136\.syslab-vscode\completion.json（共 1498 项，3 个包）
[完成] 生成代码补全索引：1498 项，399.5 KB，耗时 14.1 秒
       function=1307  type=112  const=37  module=34  value=8
```

索引格式（结构示意）：

```json
{
  "generatedAt": "2026-09-17T00:45:00",
  "julia": "1.10.10+12",
  "project": "C:\\Users\\Public\\TongYuan\\.julia\\environments\\v1.10\\Project.toml",
  "packages": ["TyBase", "TyMath", "TyPlot"],
  "items": [
    { "n": "figure", "k": "function", "p": "TyPlot", "d": "figure - 创建图窗窗口 此 Syslab 函数 使用默认属性值创建一个新的图窗窗口。…" }
  ]
}
```

### 补全行为（实测）

| 你输入 | 触发方式 | 弹出的候选（实测） |
| --- | --- | --- |
| `pl` | 打字即补全 | `plan_fft` / `planerot` / `plot` / `plot3` / `plotmatrix` / `plotyy` …（37 项，全部包的符号并集） |
| `TyPlot.fi` | 输入 `.` | `figure` / `figuregroup` / `fimplicit` / `findobj`（4 项，只列 TyPlot 导出的成员） |
| `TyMath.fi` | 输入 `.` | `fibonacci` / `filter1` / `filter2` / `findedge` / `findnode` / `findnz` |
| `using TyA` | 打字即补全 | `TyAppDesigner`（`using`/`import` 之后按包名补全） |
| 停在候选上 | — | 显示索引里的一行文档（TyPlot/TyMath 是中文说明） |

* 触发字符 `.`，生效语言 `julia` 与 `juliamarkdown`；
* 前缀匹配先精确、后忽略大小写；同名符号只保留一个（按包顺序优先）；
* 候选按 种类 排序（function → type → module → const → value）。

### 设置

| 设置 | 默认 | 说明 |
| --- | --- | --- |
| `syslab.completion.enable` | `true` | 总开关 |
| `syslab.completion.file` | `""` | 索引路径；留空 = `%USERPROFILE%\.syslab-vscode\completion.json` |
| `syslab.completion.maxItems` | `200` | 单次最多返回多少项 |
| `syslab.completion.documentation` | `true` | 是否显示索引里的一行文档 |

### 命令与维护

* `Syslab: 生成代码补全索引` —— 调 `scripts\Build-CompletionIndex.ps1`（按 `syslab.kitPath` 定位脚本）；
* `Syslab: 重新载入代码补全索引` —— 输出当前条目数/包列表，并让补全器立刻重读；
  索引按文件 mtime 自动感知，手动改了文件不重载也会生效。

自检（读真实索引，断言上下文解析/前缀/成员/包名四类检索）：

```powershell
powershell -File scripts\Test-CompletionIndex.ps1
```

```
索引文件 : C:\Users\29136\.syslab-vscode\completion.json
索引内容 : 1498 项 / 3 个包 TyBase,TyMath,TyPlot
生成信息 : julia 1.10.10+12 | 2026-09-17T00:45:00
  [通过] 索引条目数 > 100  实际 1498
  [通过] 索引里记录了包列表  TyBase,TyMath,TyPlot
  [通过] 解析「空行无前缀」  prefix="" memberOf=null inUsing=false
  [通过] 解析「标识符前缀 pl」  prefix="pl" memberOf=null inUsing=false
  [通过] 解析「成员访问 TyPlot.fi」  prefix="fi" memberOf=TyPlot inUsing=false
  [通过] 解析「赋值右侧 TyPlot.su」  prefix="su" memberOf=TyPlot inUsing=false
  [通过] 解析「using 之后的包名」  prefix="TyA" memberOf=null inUsing=true
  [通过] 前缀 pl 有候选  37 项
  [通过] 前缀 pl 的候选都以 pl 开头  plan_bfft, plan_bfft!, plan_brfft, plan_dct, plan_dct!, plan_fft
  [通过] 成员补全 TyPlot.fi 有候选  4 项: figure, figuregroup, fimplicit, findobj
  [通过] 成员补全 TyPlot.fi 只含 TyPlot  TyPlot
  [通过] 成员补全 TyPlot.fi 都以前缀开头  figure, figuregroup, fimplicit, findobj
  [通过] TyPlot.fi 命中 figure  figure, figuregroup, fimplicit, findobj
  [通过] 成员补全 TyMath.fi 有候选  7 项: fibonacci, fibonacci_error, filter1, filter2, findedge, findnode, findnz
  [通过] 成员补全 TyMath.fi 只含 TyMath  TyMath
  [通过] 成员补全 TyMath.fi 都以前缀开头  fibonacci, fibonacci_error, filter1, filter2, findedge, findnode, findnz
  [通过] using TyA 命中 TyAppDesigner  TyAppDesigner
  [通过] using TyA 结果都是 TyA 开头  TyAppDesigner
文档抽样 : [TyBase] @__dot__ —— @. expr Convert every function call or operator in expr into a "dot ca
全部检查通过：离线补全索引可用 ✓
```

**新增包之后**：`Pkg.add` 装进 Syslab 默认环境 → 重新生成索引（命令面板第一条，或直接跑脚本）→ 补全立即包含新包。
`install.ps1` 只按**当时**的 `syslab.preloadPackages` 生成索引，所以「改预加载包 → 重建索引」是配套动作。

### 局限（提前说清）

* 这是**静态快照**：只含生成时被 `using` 的那些包 **导出** 的符号。函数里的局部变量、宏展开生成的符号、
  运行时动态定义的名字都不在索引里。
* 只补名字 + 一行文档，**没有方法签名/参数提示**，也不做类型推断——那些要真正的语言服务器。
* 索引是明文 JSON（包名、符号名、文档首行，不含源码）。删掉它扩展会自动退化为「无补全」，不会报错。

---

## 十一、实测记录

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
    "StKGC.syslab-julia":   { "installed": true, "active": true },
    "StKGC.julia-analyzer": { "installed": true, "active": true },
    "StKGC.tymlang-ide":    { "installed": true, "active": true },
    "StKGC.app-designer":   { "installed": true, "active": true }
  },
  "shellStubs": 78,
  "completion": {
    "enabled": true,
    "file": "C:\\Users\\29136\\.syslab-vscode\\completion.json",
    "fileExists": true,
    "items": 1498,
    "packages": "TyBase,TyMath,TyPlot"
  }
}
```

`completion` 段是补全功能的现场状态：`enabled` 来自设置，`fileExists` / `items` / `packages` 是实际读到的索引。
排查「补全不弹」时先看这里——`items: 0` 或 `fileExists: false` 说明索引没生成（跑 `scripts\Build-CompletionIndex.ps1`）。
