# 扩展上云与多平台同步指南

本文说明如何把本工具包产出的扩展发布到「云端」，让**多台机器 / 多个平台（Windows / Linux / macOS）**
都能一条命令拉到并安装。

> **当前采用的分发模型**：`release/` 是**本机构建产物**（已在 `.gitignore` 中忽略，不进 git 历史），
> 发布时一把「打包 → 上传为 **GitHub Release 附件**」，其它机器用 `-GitHubRelease <owner/repo>@<tag>` /
> `--github-release <owner/repo>@<tag>` 安装。仓库里只放源码与脚本。
>
> 本仓库当前发布：**`StKGC/VScodeWithSyslab` @ `v1.2.0`**（私有，见
> https://github.com/StKGC/VScodeWithSyslab/releases/latest ），
> 附件 = 4 个同元扩展 + `StKGC.vscodewithsyslab-1.2.0.vsix` + `manifest.json` + `SHA256SUMS.txt`（共 7 个）。

---

## 0. 先分清两类扩展（合规红线）

| 扩展 | 版权 | 能否公开上架市场 |
| --- | --- | --- |
| `StKGC.vscodewithsyslab`（publisher/name 可在 `extension\package.json` 改） | 本工具包（MIT） | ✅ 可以（VS Code Marketplace） |
| `StKGC.syslab-julia` / `StKGC.julia-analyzer` / `StKGC.tymlang-ide` / `StKGC.app-designer` | 同元软控（打包时已把发布者前缀由 `TongYuan.*` 统一改写为 `StKGC.*`） | ❌ **不要**公开上架，仅限自有环境内部/私有渠道分发 |

> 因此推荐做法：**桥接扩展上市场（享受自动同步），同元的扩展走私有的发布包 + 引导脚本。**
>
> **前缀改写想恢复原样**：`Build-SyslabVsix.ps1 -Publisher TongYuan`，或改 `extension\package.json`
> 的 `publisher` 后重新打包。改写只发生在 VSIX 副本里，Syslab 安装目录始终是原始的 `tongyuan.*`。

---

## 1. 渠道选择

| 渠道 | 适用 | 优点 | 注意 |
| --- | --- | --- | --- |
| **GitHub Release 附件（当前采用）** | 个人/小团队 | 免费、版本化、可脚本下载、不占 git 历史 | 私有仓库需 Token（脚本会自动取 git 凭据）；单文件 ≤2GB |
| 对象存储 / 静态站点（OSS/S3/COS/MinIO） | 团队、跨地域 | 稳定、可 CDN、可鉴权 | 需把 `release/` 目录整个上传并保持相对路径 |
| 内网 HTTP（nginx / IIS / `python3 -m http.server`） | 公司内网 | 最简单、无外网依赖 | 记得配 HTTPS + 访问控制 |
| 网盘 / SMB 共享（OneDrive、NAS、`\\server\share`） | 临时分发 | 零成本 | 脚本用本地路径即可，无需 HTTP |

发布包结构（`Pack-ExtensionRelease.ps1` 生成，本机产物，不入库）：

```
release/
├─ manifest.json      # 扩展 ID/版本/文件名/SHA256/适用平台
├─ SHA256SUMS.txt     # sha256sum -c 可直接校验
├─ StKGC.syslab-julia-26.1.0.vsix
├─ StKGC.julia-analyzer-26.4.0.vsix
├─ StKGC.tymlang-ide-26.1.0.vsix
├─ StKGC.app-designer-26.1.0.vsix
└─ StKGC.vscodewithsyslab-1.2.0.vsix   # 本工具包自带（MIT）
```

---

## 2. 生成发布包 + 上传为 Release 附件（推荐一条命令）

```powershell
# 打包 + 创建/更新 Release 并上传附件（私有仓库自动使用 git 凭据管理器里的令牌）
powershell -ExecutionPolicy Bypass -File scripts\Pack-ExtensionRelease.ps1 `
    -PackVersion 1.2.0 `
    -PublishGitHub StKGC/VScodeWithSyslab `
    -Tag v1.2.0

# 只打包不上传（本地/其它渠道分发时用）
powershell -ExecutionPolicy Bypass -File scripts\Pack-ExtensionRelease.ps1 -PackVersion 1.2.1 -Zip
```

参数：

* `-PackVersion`：发布包版本（本仓库用扩展版本号，如 `1.2.0`；也可用 `年.月日`）
* `-PublishGitHub <owner/repo>`：上传为 Release 附件；`-Tag` 默认 `v<PackVersion>`
* `-Token`：GitHub 令牌（默认取 `$env:GITHUB_TOKEN` / `$env:GH_TOKEN` / git 凭据管理器）
* `-IncludeCopilot`：把 MWORKS Copilot 也打进去（需要 Syslab 账号/服务器，默认不含）
* `-Zip`：额外打 zip；`-IncludeZipInRelease` 连 zip 一起上传

上传结果（本仓库最新一次 `v1.2.0` 实测）：

```
Release: https://github.com/StKGC/VScodeWithSyslab/releases/tag/v1.2.0
附件   : 7 个（5 VSIX + manifest.json + SHA256SUMS.txt，约 76 MB）
```

---

## 3. 其它机器的安装方式

### 3.1 GitHub Release（推荐）

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File scripts\Install-ExtensionPack.ps1 `
    -GitHubRelease StKGC/VScodeWithSyslab@v1.2.0
#   私有仓库：脚本自动取 git 凭据；也可显式 -Token $env:GITHUB_TOKEN
#   只装桥接扩展：加 -OnlyBridge

# Linux / macOS
./install.sh --github-release StKGC/VScodeWithSyslab@v1.2.0
#   私有仓库加 --token <PAT>
```

实测输出（v1.0.0 首版记录的原始输出，流程与各版本一致）：

```
=== 1/4 获取扩展发布包 ===  GitHub Release：StKGC/VScodeWithSyslab@v1.0.0（已带令牌）
                            已下载 manifest.json / 下载 StKGC.vscodewithsyslab-1.0.0.vsix
=== 2/4 校验扩展包 ===      manifest.json：syslab-vscode-pack 1.0.0 · SHA256 校验通过
=== 3/4 安装到 VS Code ===  已安装 StKGC.vscodewithsyslab-1.0.0.vsix
=== 完成：成功安装 1 / 1 个扩展 ===
```

### 3.2 公开仓库：直接用 raw 链接（无需令牌）

```powershell
scripts\Install-ExtensionPack.ps1 -Source https://github.com/<你>/<仓库>/raw/main/release/manifest.json
./install.sh --base-url https://github.com/<你>/<仓库>/raw/main/release
```
（注意：这样需要把 `/release/` 从 `.gitignore` 里去掉并提交，仓库会因此变大——本仓库**没有**这么做。）

### 3.3 私有仓库且没有 git 凭据的机器

```powershell
git clone https://github.com/<你>/<仓库>.git
scripts\Install-ExtensionPack.ps1 -Source .\<仓库>\release      # 需该机器上已能 git 认证
# 或者：申请一个只读 PAT，用 -Token
```

### 3.4 对象存储 / 内网 HTTP / 网盘（可选渠道）

先把 `release/` 目录（或那个 zip）上传/拷贝过去：

```bash
# 对象存储（以阿里云 OSS 为例，任何静态托管同理：把 release 目录整体上传）
ossutil cp -r release/ oss://my-bucket/syslab-pack/1.0.0/ --update
# 基地址即为 https://my-bucket.oss-cn-xx.aliyuncs.com/syslab-pack/1.0.0/

# 内网临时验证
cd release && python3 -m http.server 8731 --bind 0.0.0.0
# 正式环境 nginx：location /syslab-pack/ { alias /srv/syslab-pack/; autoindex on; }
```

然后安装端指过去：

```powershell
scripts\Install-ExtensionPack.ps1 -Source https://<基地址>/          # 目录里要有 manifest.json
scripts\Install-ExtensionPack.ps1 -Source \\fileserver\share\syslab-pack
./install.sh --base-url https://<基地址>/                            # Linux/macOS
```

---

## 4. 多平台注意事项（前置条件）

| 平台 | 命令 |
| --- | --- |
| Windows | `powershell -ExecutionPolicy Bypass -File scripts\Install-ExtensionPack.ps1 -GitHubRelease <owner/repo>@<tag>` |
| Linux | `./install.sh --github-release <owner/repo>@<tag>`（或 `--base-url` / `--vsix-dir`） |
| macOS | 同 Linux |

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
当前 publisher 已设为 **`StKGC`**，扩展 ID = `StKGC.vscodewithsyslab`（市场里统一记为小写 `stkgc.vscodewithsyslab`）。

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
npx --yes @vscode/vsce publish --packagePath vsix\StKGC.vscodewithsyslab-1.0.0.vsix
```

发布成功后：

```powershell
code --install-extension stkgc.vscodewithsyslab     # 一条命令，任何平台
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

**Q：`git push` 报 TLS 握手失败/超时，但网页和 API 都正常？**
A：多是本机代理按进程分流（`git.exe` 被直连，而 `powershell.exe`/浏览器走代理）导致的。
两条路：
1）把 `git.exe` 也加入代理，或直接给 git 配代理（本机代理端口 7897）：

```powershell
git -c http.proxy=http://127.0.0.1:7897 -c https.proxy=http://127.0.0.1:7897 push origin main
```

2）改走 GitHub API 推送（内容与本地提交**逐字节一致**，不会分叉）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\Push-ViaGitHubApi.ps1 -Repository StKGC/VScodeWithSyslab
#   它会逐文件比对 blob SHA、tree SHA、commit SHA，全都相等才更新 refs/heads/main
```

**Q：机器没网/内网隔离怎么办？**
A：把 `syslab-vscode-pack-<版本>.zip` 拷过去解压，然后
