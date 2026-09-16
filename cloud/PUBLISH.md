# 扩展上云与多平台同步指南

本文说明如何把本工具包产出的扩展发布到「云端」，让**多台机器 / 多个平台（Windows / Linux / macOS）**
都能一条命令拉到并安装。

---

## 0. 先分清两类扩展（合规红线）

| 扩展 | 版权 | 能否公开上架市场 |
| --- | --- | --- |
| `StKGC.syslab-bridge`（publisher 可在 `extension\package.json` 改） | 本工具包（MIT） | ✅ 可以（VS Code Marketplace） |
| `TongYuan.syslab-julia` / `julia-analyzer` / `tymlang-ide` / `app-designer` | 同元软控 | ❌ **不要**公开上架，仅限自有环境内部/私有渠道分发 |

> 因此推荐做法：**桥接扩展上市场（享受自动同步），同元的扩展走私有的发布包 + 引导脚本。**

---

## 1. 渠道选择

| 渠道 | 适用 | 优点 | 注意 |
| --- | --- | --- | --- |
| GitHub Release（公开或私有仓库） | 个人/小团队 | 免费、版本化、可脚本下载 | 私有仓库下载需 Token；单文件 ≤2GB |
| 对象存储 / 静态站点（OSS/S3/COS/MinIO） | 团队、跨地域 | 稳定、可 CDN、可鉴权 | 需把 `release/` 目录整个上传并保持相对路径 |
| 内网 HTTP（nginx / IIS / `python3 -m http.server`） | 公司内网 | 最简单、无外网依赖 | 记得配 HTTPS + 访问控制 |
| 网盘 / SMB 共享（OneDrive、NAS、`\\server\share`） | 临时分发 | 零成本 | 脚本用本地路径即可，无需 HTTP |

发布包结构（`Pack-ExtensionRelease.ps1` 生成）：

```
release/
├─ manifest.json      # 扩展 ID/版本/文件名/SHA256/适用平台
├─ SHA256SUMS.txt     # sha256sum -c 可直接校验
├─ TongYuan.syslab-julia-26.1.0.vsix
├─ TongYuan.julia-analyzer-26.4.0.vsix
├─ TongYuan.tymlang-ide-26.1.0.vsix
├─ TongYuan.app-designer-26.1.0.vsix
└─ StKGC.syslab-bridge-1.0.0.vsix     # 本工具包自带（publisher 可在 extension\package.json 改）
```

---

## 2. 生成发布包

```powershell
# Windows 侧（需要本机已装 MWORKS.Syslab）
powershell -ExecutionPolicy Bypass -File scripts\Pack-ExtensionRelease.ps1 -PackVersion 2026.0916 -Zip
#   -> release\            可直接上传的目录
#   -> syslab-vscode-pack-2026.0916.zip   便于传网盘/Release 附件
```

参数：

* `-PackVersion`：发布包版本（建议 `年.月日` 或语义化版本，便于多版本共存与回滚）
* `-IncludeCopilot`：把 MWORKS Copilot 也打进去（需要 Syslab 账号/服务器，默认不含）
* `-Zip`：额外打 zip

---

## 3. 上传到云端

### 3.0 本仓库现成的方式（仓库内已带 release/）

本工具包仓库自身就是发布源，`release/` 已随仓库提交（VSIX + manifest.json + SHA256SUMS）。

**公开仓库**（推荐，其它机器零凭据一条命令）：

```powershell
# Windows
scripts\Install-ExtensionPack.ps1 -Source https://github.com/<你>/<仓库>/raw/main/release/manifest.json
# Linux / macOS
./install.sh --base-url https://github.com/<你>/<仓库>/raw/main/release
```

**私有仓库**（匿名 raw 会返回 404，用下面两种方式之一）：

```powershell
# 方式 A（推荐）：用 git 克隆后再本地安装，凭据交给 git/GCM，不用手管 Token
git clone https://github.com/<你>/<仓库>.git
scripts\Install-ExtensionPack.ps1 -Source .\<仓库>\release
#   Linux / macOS： ./install.sh --vsix-dir ./<仓库>/release

# 方式 B：给 raw 直链带 PAT（classic PAT 用 token 前缀，fine-grained 用 Bearer）
scripts\Install-ExtensionPack.ps1 `
  -Source https://raw.githubusercontent.com/<你>/<仓库>/main/release/manifest.json `
  -Token $env:GH_TOKEN
```

> 判断仓库是公开还是私有：浏览器无痕窗口打开
> `https://raw.githubusercontent.com/<你>/<仓库>/main/release/manifest.json`，
> 能看到 JSON 就是公开；404 则是私有。
> 想让所有人（或没有 git 凭据的机器）直接下载，把仓库改成 Public 即可
> （Settings → General → Danger Zone → Change visibility）。

### 3.1 GitHub Release

```bash
# 一次性
git remote add origin https://github.com/<你>/<仓库>.git

# 打 tag + Release，界面上把 release 目录里的文件作为附件上传（或用 gh CLI）
git tag v2026.0916 && git push origin v2026.0916
# 若已安装 gh：gh release create v2026.0916 release/* --title "Syslab pack 2026.0916"
```

安装端（私有仓库必须带 Token）：

```powershell
# GitHub Release 附件直链（公开）
scripts\Install-ExtensionPack.ps1 -Source https://github.com/<你>/<仓库>/releases/download/v2026.0916/manifest.json
# 私有仓库
scripts\Install-ExtensionPack.ps1 -Source https://github.com/... -Token $env:GH_TOKEN
```

> 也可以只把 `syslab-vscode-pack-2026.0916.zip` 作为唯一附件上传，安装端 `-Source https://.../syslab-vscode-pack-2026.0916.zip`。

### 3.2 对象存储 / 静态站点

```bash
# 以阿里云 OSS 为例（任何静态托管同理：把 release 目录整体上传）
ossutil cp -r release/ oss://my-bucket/syslab-pack/2026.0916/ --update
# 基地址即为 https://my-bucket.oss-cn-xx.aliyuncs.com/syslab-pack/2026.0916/
```

安装端：`-Source <基地址>/`（脚本会自动取 `<基地址>/manifest.json`）。
需要鉴权的对象存储，可改用带签名的直链，或用 `-Token`（Bearer）。

### 3.3 内网 HTTP

```bash
# 最快验证方式（临时）
cd release && python3 -m http.server 8731 --bind 0.0.0.0
# 正式环境：nginx 指向 release 目录
#   location /syslab-pack/ { alias /srv/syslab-pack/; autoindex on; }
```

安装端：`-Source http://<ip>:8731/`

### 3.4 网盘 / 共享目录

```powershell
# 直接指向解压后的目录或 UNC 路径，无需 HTTP
scripts\Install-ExtensionPack.ps1 -Source D:\share\syslab-pack
scripts\Install-ExtensionPack.ps1 -Source \\fileserver\share\syslab-pack
```

---

## 4. 其它机器安装（多平台）

| 平台 | 命令 |
| --- | --- |
| Windows | `powershell -ExecutionPolicy Bypass -File scripts\Install-ExtensionPack.ps1 -Source <基地址或目录>` |
| Linux | `./install.sh --base-url <基地址>`（或 `--vsix-dir /path/to/release`） |
| macOS | 同 Linux（`./install.sh --base-url <基地址>`） |

Windows 的 `Install-ExtensionPack.ps1` 会：下载 → 按 `manifest.json` 校验 SHA256 → `code --install-extension --force`
→ 调用 `install.ps1 -SkipExtensions` 写入 Syslab 环境变量与 VS Code 设置。

只想要桥接扩展（不含同元扩展）时加 `-OnlyBridge`。

**前置条件**：目标机器本身要装 MWORKS.Syslab（提供 Julia 运行时与 TyBase/TyMath/TyPlot）。
扩展是“通用 VSIX”，但**环境变量必须由本机脚本生成**（各平台路径不同）：

* Windows：`install.ps1`
* Linux/macOS：`install.sh`（按 Syslab 的 `out/syslab-environment-linux.js` 复刻：
  `JULIA_HOME=<SyslabHome>/Tools/<juliaVersion>`、`JULIA_DEPOT_PATH=$HOME/TongYuan/.julia:<SyslabHome>/.julia`、
  `LD_LIBRARY_PATH`、`XDG_RUNTIME_DIR` 等）

---

## 5. VS Code 多平台同步：真相与建议

**VS Code Settings Sync 同步的是“扩展清单（ID + 版本）”，不是扩展文件本身**；新机器会去
**扩展市场**重新下载。因此：

* 上架了市场的扩展（例如桥接扩展）→ 打开 Settings Sync 即自动装好，跨平台开箱可用 ✅
* 只存在于私有发布包的扩展（同元的 4 个）→ **不会被 Sync 同步**，需要在每台机器跑一次引导脚本，
  或用下面的兜底方案。

兜底方案（推荐组合）：

1. **桥接扩展上市场**，Settings Sync 自动同步；
2. 同元扩展用引导脚本：把
   `powershell -File scripts\Install-ExtensionPack.ps1 -Source <基地址> -OnlyBridge:$false`（Windows）
   或 `./install.sh --base-url <基地址>`（Linux/macOS）放进
   * 新机器初始化流程 / 开机任务 / Ansible、Intune、SCCM 等；
3. 可选：在项目里放 `.vscode/tasks.json` 加一个 “同步 Syslab 扩展” 任务，一键执行上面的命令；
4. 学习/办公环境可把 `settingsSync.ignoredExtensions` 留空，并保持
   `"extensions.autoUpdate": true`，让市场扩展自动更新。

> 注意：`.vscode/extensions.json`（workspace recommendations）只能“推荐”，不能安装非市场扩展；
> 需要“自动装好”就必须走上面的引导脚本。

---

## 6. 只上架桥接扩展（可选，享受自动同步）

市场目前**不能**上传别人有版权的扩展，所以只上架本工具包自带的桥接扩展（MIT）。
当前 publisher 已设为 **`StKGC`**，扩展 ID = `StKGC.syslab-bridge`（市场里统一记为小写 `stkgc.syslab-bridge`）。

前置（一次性）：

1. 安装 Node.js LTS：`winget install --id OpenJS.NodeJS.LTS -e`（或 https://nodejs.org）
2. 生成 PAT：https://dev.azure.com → User settings → Personal access tokens
   · Organization 选 **All accessible organizations**，Scopes 勾 **Marketplace → Manage**
3. 创建同名 publisher：https://marketplace.visualstudio.com/manage
   （名字必须与 `extension\package.json` 的 `publisher` 一致，本仓库是 `StKGC`）

发布（本仓库已封装好脚本，会自动打包 + 校验 manifest + 调 vsce）：

```powershell
$env:VSCE_PAT = '<你的PAT>'          # 也可用 -Pat 参数传入
powershell -ExecutionPolicy Bypass -File scripts\Publish-Marketplace.ps1
#   -PackageOnly  只打包不上架（先检查）；-SkipDuplicate  版本已存在时跳过
```

等效的手工命令（脚本内部就是这一条）：

```powershell
npx --yes @vscode/vsce publish --packagePath vsix\StKGC.syslab-bridge-1.0.0.vsix
```

发布成功后：

```powershell
code --install-extension stkgc.syslab-bridge     # 一条命令，任何平台
```

并且 Settings Sync 会自动把它同步到你的其它机器 / 其它平台。

> 想换发布者：只改 `extension\package.json` 里的 `publisher` 一处，其余脚本（打包、发布、
> 安装、卸载、发布包 manifest）都会自动跟随，重新 `Publish-Marketplace.ps1` 即可。

> Open VSX 也可作为备选渠道（开源、免费），但**标准 VS Code 与 MWORKS Syslab 用的都是微软市场**，
> 只有 VSCodium 等以 Open VSX 为默认市场的编辑器才会自动装到。

---

## 7. 校验与安全

```powershell
# Windows 校验（对照 release\SHA256SUMS.txt）
Get-FileHash .\release\*.vsix -Algorithm SHA256 | Format-Table Hash,Path
```

```bash
# Linux / macOS
cd release && sha256sum -c SHA256SUMS.txt
```

* 私有渠道建议用 HTTPS + 短期 Token（`-Token`）；
* 发布目录建议带版本号（`.../2026.0916/`），回滚只需把 `-Source` 指回旧版本；
* 每次打包都会重新计算 SHA256，客户端默认强校验（`-SkipVerify` 可跳过，不建议）。

---

## 8. 常见问题

**Q：能不能把同元的扩展也放到市场，省得每台机器跑脚本？**
A：不可以。这属于再分发他人软件，违反其许可；且市场会因版权/签名问题下架。请走私有发布包。

**Q：Linux/macOS 上装 Windows 打出来的 VSIX 可以吗？**
A：这些扩展是纯 JS + 自带多平台服务（`julia-analyzer` 内含 `server-windows-latest` /
`server-ubuntu-latest` / `server-ubuntu-24.04-arm`），因此通用 VSIX 可以装；
但**环境变量必须在该平台由 `install.sh` 生成**，并且该平台要有 MWORKS.Syslab 安装。

**Q：`code --install-extension` 支持直接给 URL 吗？**
A：不同版本行为不一致，本工具包统一**先下载再本地安装**，并对下载物做 SHA256 校验，更可靠。

**Q：机器没网/内网隔离怎么办？**
A：把 `syslab-vscode-pack-<版本>.zip` 拷过去解压，然后
`Install-ExtensionPack.ps1 -Source <解压目录>` / `./install.sh --vsix-dir <解压目录>`。
