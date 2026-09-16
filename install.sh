#!/usr/bin/env bash
# =============================================================================
#  MWORKS Syslab x VS Code —— Linux / macOS 安装脚本
#
#  功能与 Windows 的 install.ps1 对齐：
#    1. 探测 MWORKS.Syslab 安装目录与自带 Julia；
#    2. 生成 ~/.syslab-vscode/env.json 与 env.sh（环境变量与 Syslab 主程序一致，
#       参照 Syslab 的 out/syslab-environment-linux.js）；
#    3. 安装 Syslab 自带扩展 + 桥接扩展（本地 vsix 目录，或从云端发布包下载）；
#    4. 合并 VS Code 用户设置（julia 解释器路径、终端环境、Syslab 终端配置文件）。
#
#  用法：
#    ./install.sh                                   # 用本机 Syslab + 本地 vsix 目录
#    ./install.sh --base-url https://x/pack/        # 从云端发布包下载安装
#    ./install.sh --syslab-home /opt/MWORKS/Syslab\ 2026b
#    ./install.sh --skip-extensions                 # 只写环境变量与设置
#    ./install.sh --help
# =============================================================================
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SYSLAB_HOME_ARG=""
TONGYUAN_PATH_ARG=""
BASE_URL=""
VSIX_DIR=""
CODE_CLI=""
EXTENSIONS_DIR=""
TOKEN=""
ONLY_BRIDGE=0
SKIP_SETTINGS=0
SKIP_EXTENSIONS=0

BRIDGE_ID=""   # 由 extension/package.json 解析（小写），见「定位 VS Code 与扩展包」一节

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

可选参数：
  --syslab-home <dir>     MWORKS.Syslab 安装目录（默认自动探测）
  --tongyuan-path <dir>   共享数据目录（默认 $HOME/TongYuan；Linux 下 Syslab 即用此默认值）
  --vsix-dir <dir>        本地 VSIX 目录（默认 <工具包>/release，其次 <工具包>/vsix）
  --base-url <url>        云端发布包基地址（目录中含 manifest.json 与 *.vsix）
  --token <token>         私有仓库访问令牌（Bearer）
  --code-cli <path>       code 命令行路径（默认自动探测，macOS 会找 /Applications/...）
  --extensions-dir <dir>  扩展目录（默认 ~/.vscode/extensions）
  --only-bridge           只安装桥接扩展
  --skip-extensions       跳过扩展安装
  --skip-settings         跳过 settings.json 合并
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --syslab-home)     SYSLAB_HOME_ARG="${2:-}"; shift 2 ;;
        --tongyuan-path)   TONGYUAN_PATH_ARG="${2:-}"; shift 2 ;;
        --vsix-dir)        VSIX_DIR="${2:-}"; shift 2 ;;
        --base-url)        BASE_URL="${2:-}"; shift 2 ;;
        --token)           TOKEN="${2:-}"; shift 2 ;;
        --code-cli)        CODE_CLI="${2:-}"; shift 2 ;;
        --extensions-dir)  EXTENSIONS_DIR="${2:-}"; shift 2 ;;
        --only-bridge)     ONLY_BRIDGE=1; shift ;;
        --skip-extensions) SKIP_EXTENSIONS=1; shift ;;
        --skip-settings)   SKIP_SETTINGS=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "未知参数：$1"; usage; exit 1 ;;
    esac
done

step()  { printf '\n=== %s ===\n' "$1"; }
ok()    { printf '  [OK]   %s\n' "$1"; }
info()  { printf '  [信息] %s\n' "$1"; }
warn()  { printf '  [注意] %s\n' "$1"; }

OS="$(uname -s)"
case "$OS" in
    Linux)  PLATFORM_LABEL="linux" ;;
    Darwin) PLATFORM_LABEL="darwin" ;;
    *)      PLATFORM_LABEL="$(echo "$OS" | tr '[:upper:]' '[:lower:]')" ;;
esac

# ---------------------------------------------------------------------------
# 1. 定位 Syslab
# ---------------------------------------------------------------------------
is_syslab_home() {
    [ -n "${1:-}" ] && [ -f "$1/Bin/resources/app/product.json" ]
}

find_syslab_home() {
    if is_syslab_home "$SYSLAB_HOME_ARG"; then echo "$SYSLAB_HOME_ARG"; return 0; fi
    if is_syslab_home "${SYSLAB_HOME:-}"; then echo "$SYSLAB_HOME"; return 0; fi

    local roots=(
        /opt/MWORKS/Syslab /opt/MWORKS /opt/syslab /usr/local/MWORKS/Syslab /usr/local/syslab
        "$HOME/MWORKS/Syslab" "$HOME/syslab" "$HOME/opt/MWORKS/Syslab"
        /Applications/MWORKS /Applications
    )
    local root candidate
    for root in "${roots[@]}"; do
        [ -d "$root" ] || continue
        if is_syslab_home "$root"; then echo "$root"; return 0; fi
        while IFS= read -r candidate; do
            if is_syslab_home "$candidate"; then echo "$candidate"; return 0; fi
        done < <(find "$root" -maxdepth 3 -type d -name 'Syslab*' 2>/dev/null || true)
    done
    return 0
}

step "1/5 解析 MWORKS.Syslab 环境"
SYSLAB_HOME="$(find_syslab_home)"
if [ -z "$SYSLAB_HOME" ]; then
    echo "  未找到 MWORKS.Syslab 安装目录，请用 --syslab-home 指定（需包含 Bin/resources/app/product.json）" >&2
    exit 1
fi
SYSLAB_HOME="${SYSLAB_HOME%/}"
PRODUCT_JSON="$SYSLAB_HOME/Bin/resources/app/product.json"

json_get() {  # <file> <key>
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8")).get(sys.argv[2],"") or "")' "$1" "$2"
    else
        grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/'
    fi
}

JULIA_VERSION="$(json_get "$PRODUCT_JSON" juliaVersion)"
SYSLAB_VERSION="$(json_get "$PRODUCT_JSON" syslabVersion)"
SYSLAB_TITLE="$(json_get "$PRODUCT_JSON" syslabTitleName)"
CACHE_SUFFIX="$(json_get "$PRODUCT_JSON" syslabCachePath)"
LOGS_SUFFIX="$(json_get "$PRODUCT_JSON" syslabLogsPath)"
TONGYUAN_PATH="${TONGYUAN_PATH_ARG:-$(json_get "$PRODUCT_JSON" syslabUserDataPath)}"
[ -n "$TONGYUAN_PATH" ] || TONGYUAN_PATH="$HOME/TongYuan"
TONGYUAN_PATH="${TONGYUAN_PATH%/}"

[ -n "$JULIA_VERSION" ] || { echo "  product.json 缺少 juliaVersion" >&2; exit 1; }

JULIA_HOME="$SYSLAB_HOME/Tools/$JULIA_VERSION"
JULIA_BASE_DEPOT="$SYSLAB_HOME/.julia"
JULIA_DEPOT_PATH="$TONGYUAN_PATH/.julia:$JULIA_BASE_DEPOT"
SYSLAB_JULIA_PATH="$TONGYUAN_PATH/syslab-julia"
CONDA3="$JULIA_BASE_DEPOT/miniforge3"
JULIA_EXE="$JULIA_HOME/bin/julia"

case "$CACHE_SUFFIX" in
    /*) BITANSWER_ROOT_PATH="$TONGYUAN_PATH$CACHE_SUFFIX" ;;
    "") BITANSWER_ROOT_PATH="$TONGYUAN_PATH/.tycache" ;;
    *)  BITANSWER_ROOT_PATH="$CACHE_SUFFIX" ;;
esac

ok "Syslab      : $SYSLAB_HOME"
ok "版本        : ${SYSLAB_TITLE:-MWORKS.Syslab} ${SYSLAB_VERSION}"
ok "Julia       : $JULIA_HOME"
ok "Depot       : $JULIA_DEPOT_PATH"
[ -x "$JULIA_EXE" ] || warn "未找到 julia 可执行文件：$JULIA_EXE"

# ---------------------------------------------------------------------------
# 2. 生成环境文件
# ---------------------------------------------------------------------------
step "2/5 生成环境文件（~/.syslab-vscode）"
ENV_DIR="$HOME/.syslab-vscode"
mkdir -p "$ENV_DIR"

# PATH / LD_LIBRARY_PATH
PATH_PARTS="$JULIA_HOME/bin:$JULIA_HOME/lib:$JULIA_HOME/lib/julia"
[ -d "$SYSLAB_HOME/Tools/SyslabCC" ] && PATH_PARTS="$PATH_PARTS:$SYSLAB_HOME/Tools/SyslabCC"
[ -d "$SYSLAB_HOME/Tools/zig" ] && PATH_PARTS="$PATH_PARTS:$SYSLAB_HOME/Tools/zig"
if [ -d "$CONDA3" ]; then
    PATH_PARTS="$PATH_PARTS:$CONDA3:$CONDA3/bin"
fi
PATH_PARTS="$PATH_PARTS:${PATH:-}"
LD_LIBRARY_PATH_VALUE="$JULIA_HOME/lib:$JULIA_HOME/lib/julia${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

KV_FILE="$(mktemp)"
{
    printf 'SYSLAB_HOME=%s\n'                 "$SYSLAB_HOME"
    printf 'TONGYUAN_PATH=%s\n'               "$TONGYUAN_PATH"
    printf 'JULIA_HOME=%s\n'                  "$JULIA_HOME"
    printf 'SYSLAB_JULIA_PATH=%s\n'           "$SYSLAB_JULIA_PATH"
    printf 'JULIA_DEPOT_PATH=%s\n'            "$JULIA_DEPOT_PATH"
    printf 'PATH=%s\n'                        "$PATH_PARTS"
    printf 'PYTHON=%s\n'                      "$CONDA3/bin/python"
    printf 'KMP_DUPLICATE_LIB_OK=TRUE\n'
    printf 'JULIA_CONDAPKG_BACKEND=Null\n'
    printf 'PYTHON_JULIAPKG_OFFLINE=yes\n'
    printf 'JULIA_PYTHONCALL_EXE=@PyCall\n'
    printf 'TYPY_JL_EXE=%s\n'                 "$JULIA_EXE"
    printf 'LD_LIBRARY_PATH=%s\n'             "$LD_LIBRARY_PATH_VALUE"
    printf 'BITANSWER_ROOT_PATH=%s\n'         "$BITANSWER_ROOT_PATH"
    printf 'XDG_RUNTIME_DIR=%s\n'             "$TONGYUAN_PATH/.tycache/sock"
    printf 'JULIA_PKG_PRESERVE_TIERED_INSTALLED=true\n'
    printf 'SYSLAB_VERSION=%s\n'              "$SYSLAB_VERSION"
    printf 'TYPLOT_INTERACTIVE=true\n'
    printf 'JULIA_USE_FLISP_PARSER=1\n'
    [ -d /usr/share/terminfo ] && printf 'TERMINFO=/usr/share/terminfo\n'
} > "$KV_FILE"

json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' <<<"$1"; }

{
    printf '{\n'
    printf '  "generatedAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "syslabHome": "%s",\n' "$(json_escape "$SYSLAB_HOME")"
    printf '  "tongYuanPath": "%s",\n' "$(json_escape "$TONGYUAN_PATH")"
    printf '  "juliaVersion": "%s",\n' "$(json_escape "$JULIA_VERSION")"
    printf '  "syslabVersion": "%s",\n' "$(json_escape "$SYSLAB_VERSION")"
    printf '  "title": "%s",\n' "$(json_escape "${SYSLAB_TITLE:-MWORKS.Syslab}")"
    printf '  "platform": "%s",\n' "$PLATFORM_LABEL"
    printf '  "values": {\n'
    first=1
    while IFS= read -r line; do
        key="${line%%=*}"; value="${line#*=}"
        [ "$first" -eq 1 ] || printf ',\n'
        printf '    "%s": "%s"' "$(json_escape "$key")" "$(json_escape "$value")"
        first=0
    done < "$KV_FILE"
    printf '\n  }\n}\n'
} > "$ENV_DIR/env.json"
rm -f "$KV_FILE"
ok "env.json    : $ENV_DIR/env.json"

{
    echo "# MWORKS Syslab 环境变量（由 install.sh 生成，勿手工修改）"
    while IFS= read -r line; do
        key="${line%%=*}"; value="${line#*=}"
        printf 'export %s=%q\n' "$key" "$value"
    done < <(
        python3 - "$ENV_DIR/env.json" <<'PY' 2>/dev/null || true
import json,sys
data=json.load(open(sys.argv[1],encoding="utf-8"))
for k,v in data["values"].items():
    print(f"{k}={v}")
PY
    )
} > "$ENV_DIR/env.sh" 2>/dev/null || true
[ -s "$ENV_DIR/env.sh" ] && ok "env.sh      : $ENV_DIR/env.sh"

# ---------------------------------------------------------------------------
# 3. 定位 VS Code 与扩展来源
# ---------------------------------------------------------------------------
step "3/5 定位 VS Code 与扩展包"
if [ -z "$CODE_CLI" ]; then
    for candidate in "$(command -v code 2>/dev/null || true)" \
                     "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
                     "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
                     "$(command -v codium 2>/dev/null || true)"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then CODE_CLI="$candidate"; break; fi
    done
fi
[ -n "$CODE_CLI" ] || warn "未找到 code 命令行；可用 --code-cli 指定（扩展将只下载不安装）"
[ -n "$CODE_CLI" ] && ok "code CLI    : $CODE_CLI"

if [ -z "$EXTENSIONS_DIR" ]; then EXTENSIONS_DIR="$HOME/.vscode/extensions"; fi
ok "扩展目录    : $EXTENSIONS_DIR"

RELEASE_DIR=""
if [ -n "$VSIX_DIR" ]; then RELEASE_DIR="$VSIX_DIR"
elif [ -f "$KIT_ROOT/release/manifest.json" ]; then RELEASE_DIR="$KIT_ROOT/release"
elif [ -d "$KIT_ROOT/vsix" ]; then RELEASE_DIR="$KIT_ROOT/vsix"
fi
[ -n "$RELEASE_DIR" ] && ok "本地扩展包  : $RELEASE_DIR"

# 桥接扩展 ID（小写，来自 extension/package.json，便于换发布者）
BRIDGE_PKG="$KIT_ROOT/extension/package.json"
if [ -f "$BRIDGE_PKG" ]; then
    BRIDGE_ID="$(json_get "$BRIDGE_PKG" publisher).$(json_get "$BRIDGE_PKG" name)"
    BRIDGE_ID="$(printf '%s' "$BRIDGE_ID" | tr '[:upper:]' '[:lower:]')"
    ok "桥接扩展    : $BRIDGE_ID"
fi

if [ -z "$RELEASE_DIR" ] && [ -z "$BASE_URL" ]; then
    warn "既没有本地 VSIX 目录也没有 --base-url，跳过扩展安装"
    SKIP_EXTENSIONS=1
fi

# ---------------------------------------------------------------------------
# 4. 安装扩展
# ---------------------------------------------------------------------------
TMP_DIR=""
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

if [ "$SKIP_EXTENSIONS" -eq 0 ]; then
    step "4/5 安装扩展"

    if [ -z "$RELEASE_DIR" ] && [ -n "$BASE_URL" ]; then
        TMP_DIR="$(mktemp -d)"
        BASE="${BASE_URL%/}"
        MANIFEST_URL="$BASE/manifest.json"
        case "$BASE" in
            *.json) MANIFEST_URL="$BASE"; BASE="${BASE%/*}" ;;
            *.zip)  MANIFEST_URL="$BASE" ;;
        esac

        fetch() {  # <url> <outfile>
            if command -v curl >/dev/null 2>&1; then
                if [ -n "$TOKEN" ]; then
                    curl -fsSL -H "Authorization: Bearer $TOKEN" -o "$2" "$1"
                else
                    curl -fsSL -o "$2" "$1"
                fi
            elif command -v wget >/dev/null 2>&1; then
                wget -q -O "$2" "$1"
            else
                echo "  需要 curl 或 wget 才能从云端下载" >&2
                return 1
            fi
        }

        case "$MANIFEST_URL" in
            *.zip)
                info "下载 $MANIFEST_URL"
                fetch "$MANIFEST_URL" "$TMP_DIR/pack.zip"
                if command -v unzip >/dev/null 2>&1; then unzip -q "$TMP_DIR/pack.zip" -d "$TMP_DIR"; fi
                RELEASE_DIR="$TMP_DIR"
                ;;
            *)
                info "下载 $MANIFEST_URL"
                fetch "$MANIFEST_URL" "$TMP_DIR/manifest.json"
                RELEASE_DIR="$TMP_DIR"
                if [ -f "$TMP_DIR/manifest.json" ]; then
                    while IFS= read -r file; do
                        [ -n "$file" ] || continue
                        info "下载 $file"
                        fetch "$BASE/$file" "$TMP_DIR/$file" || warn "下载失败：$file"
                    done < <(python3 - "$TMP_DIR/manifest.json" <<'PY' 2>/dev/null || true
import json,sys
data=json.load(open(sys.argv[1],encoding="utf-8"))
for e in data.get("extensions",[]):
    print(e.get("file",""))
PY
                    )
                fi
                ;;
        esac
    fi

    # 校验 SHA256（有 manifest 时）
    if [ -f "$RELEASE_DIR/manifest.json" ] && command -v python3 >/dev/null 2>&1; then
        while IFS='|' read -r file hash; do
            [ -n "$file" ] || continue
            target="$RELEASE_DIR/$file"
            [ -f "$target" ] || { warn "缺少文件 $file"; continue; }
            actual="$( (sha256sum "$target" 2>/dev/null || shasum -a 256 "$target") | awk '{print $1}')"
            if [ "$actual" = "$hash" ]; then ok "校验通过 $file"
            else warn "校验失败 $file（期望 ${hash:0:16}…，实际 ${actual:0:16}…）"; fi
        done < <(python3 - "$RELEASE_DIR/manifest.json" <<'PY'
import json,sys
data=json.load(open(sys.argv[1],encoding="utf-8"))
for e in data.get("extensions",[]):
    print(f'{e.get("file","")}|{e.get("sha256","")}')
PY
        )
    fi

    INSTALLED=0
    for vsix in "$RELEASE_DIR"/*.vsix; do
        [ -f "$vsix" ] || continue
        name="$(basename "$vsix")"
        name_lc="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
        if [ "$ONLY_BRIDGE" -eq 1 ] && [[ "$name_lc" != *"$BRIDGE_ID"* ]]; then continue; fi
        if [ -z "$CODE_CLI" ]; then
            warn "未找到 code 命令行，跳过安装 $name（文件已就绪：$vsix）"
            continue
        fi
        if "$CODE_CLI" --install-extension "$vsix" --force >/dev/null 2>&1; then
            ok "已安装 $name"
            INSTALLED=$((INSTALLED + 1))
            # 兼容补丁：命令名冲突 / 缺失外壳命令由桥接扩展兜底
            ext_dir="$EXTENSIONS_DIR/${name%.vsix}"
            if [ -f "$ext_dir/package.json" ] && [ -f "$ext_dir/dist/extension.js" ]; then
                if grep -q 'extension\.refreshTreeView' "$ext_dir/dist/extension.js" 2>/dev/null; then
                    sed -i.bak 's/extension\.refreshTreeView/syslab.extension.refreshTreeView/g' \
                        "$ext_dir/dist/extension.js" "$ext_dir/package.json" 2>/dev/null || true
                    rm -f "$ext_dir"/*.bak
                    ok "已应用兼容补丁 $name"
                fi
            fi
        else
            warn "安装失败 $name（若 VS Code 正在运行，请关闭后重试）"
        fi
    done
    ok "本次安装 $INSTALLED 个扩展"
else
    step "4/5 跳过扩展安装"
fi

# ---------------------------------------------------------------------------
# 5. 合并 VS Code 设置
# ---------------------------------------------------------------------------
if [ "$SKIP_SETTINGS" -eq 0 ]; then
    step "5/5 写入 VS Code 用户设置"
    case "$OS" in
        Darwin) SETTINGS="$HOME/Library/Application Support/Code/User/settings.json" ;;
        *)      SETTINGS="${XDG_CONFIG_HOME:-$HOME/.config}/Code/User/settings.json" ;;
    esac
    mkdir -p "$(dirname "$SETTINGS")"

    PATCH="$(mktemp)"
    VJ="$ENV_DIR/env.json"
    json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' <<<"$1"; }
    TERM_ENV_KEY="terminal.integrated.env.linux"
    [ "$OS" = "Darwin" ] && TERM_ENV_KEY="terminal.integrated.env.osx"

    {
        printf '{\n'
        printf '  "julia.executablePath": "%s",\n' "$(json_escape "$JULIA_EXE")"
        printf '  "julia.syslab.preloadPkgs": ["TyBase", "TyMath", "TyPlot"],\n'
        printf '  "syslab.envFile": "%s",\n' "$(json_escape "$VJ")"
        printf '  "syslab.juliaExecutable": "%s",\n' "$(json_escape "$JULIA_EXE")"
        printf '  "syslab.syslabExecutable": "%s",\n' "$(json_escape "$SYSLAB_HOME/Bin/syslab")"
        printf '  "%s": {\n' "$TERM_ENV_KEY"
        printf '    "SYSLAB_HOME": "%s",\n' "$(json_escape "$SYSLAB_HOME")"
        printf '    "TONGYUAN_PATH": "%s",\n' "$(json_escape "$TONGYUAN_PATH")"
        printf '    "JULIA_HOME": "%s",\n' "$(json_escape "$JULIA_HOME")"
        printf '    "SYSLAB_JULIA_PATH": "%s",\n' "$(json_escape "$SYSLAB_JULIA_PATH")"
        printf '    "JULIA_DEPOT_PATH": "%s",\n' "$(json_escape "$JULIA_DEPOT_PATH")"
        printf '    "PATH": "%s",\n' "$(json_escape "$PATH_PARTS")"
        printf '    "LD_LIBRARY_PATH": "%s",\n' "$(json_escape "$LD_LIBRARY_PATH_VALUE")"
        printf '    "PYTHON": "%s",\n' "$(json_escape "$CONDA3/bin/python")"
        printf '    "TYPY_JL_EXE": "%s",\n' "$(json_escape "$JULIA_EXE")"
        printf '    "KMP_DUPLICATE_LIB_OK": "TRUE",\n'
        printf '    "JULIA_PYTHONCALL_EXE": "@PyCall",\n'
        printf '    "PYTHON_JULIAPKG_OFFLINE": "yes",\n'
        printf '    "JULIA_CONDAPKG_BACKEND": "Null",\n'
        printf '    "TYPLOT_INTERACTIVE": "true",\n'
        printf '    "JULIA_USE_FLISP_PARSER": "1",\n'
        printf '    "SYSLAB_VERSION": "%s"\n' "$(json_escape "$SYSLAB_VERSION")"
        printf '  }\n}\n'
    } > "$PATCH"

    if command -v python3 >/dev/null 2>&1; then
        if [ -f "$SETTINGS" ]; then cp "$SETTINGS" "$SETTINGS.syslab-bak" 2>/dev/null || true; fi
        python3 - "$SETTINGS" "$PATCH" <<'PY'
import json, re, sys, os

settings_path, patch_path = sys.argv[1], sys.argv[2]

def strip_jsonc(text):
    out, i, n = [], 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == '\\':
                i += 1
                if i < n: out.append(text[i])
            elif c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True; out.append(c); i += 1; continue
        if c == '/' and i + 1 < n and text[i+1] == '/':
            while i < n and text[i] != '\n': i += 1
            continue
        if c == '/' and i + 1 < n and text[i+1] == '*':
            i += 2
            while i + 1 < n and not (text[i] == '*' and text[i+1] == '/'): i += 1
            i += 2; continue
        out.append(c); i += 1
    return re.sub(r',(\s*[}\]])', r'\1', ''.join(out))

def deep_merge(base, extra):
    for k, v in extra.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            deep_merge(base[k], v)
        else:
            base[k] = v
    return base

data = {}
if os.path.exists(settings_path) and os.path.getsize(settings_path) > 0:
    raw = open(settings_path, encoding='utf-8-sig').read()
    try:
        data = json.loads(strip_jsonc(raw)) if raw.strip() else {}
    except Exception as exc:
        print(f"  [注意] 当前 settings.json 解析失败（{exc}），已写入备份并重建")
        open(settings_path + '.broken', 'w', encoding='utf-8').write(raw)
        data = {}
patch = json.load(open(patch_path, encoding='utf-8'))
deep_merge(data, patch)
open(settings_path, 'w', encoding='utf-8').write(json.dumps(data, indent=4, ensure_ascii=False) + '\n')
print(f"  [OK]   settings.json 已更新：{settings_path}")
PY
    else
        cp "$PATCH" "$ENV_DIR/settings.syslab.json"
        warn "未找到 python3，无法自动合并设置；已生成片段：$ENV_DIR/settings.syslab.json"
    fi
    rm -f "$PATCH"
else
    step "5/5 跳过设置写入"
fi

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
step "安装完成"
echo "  Syslab 环境文件：$ENV_DIR/env.json"
echo "  启动终端前可执行： . \"$ENV_DIR/env.sh\""
if [ -n "$CODE_CLI" ]; then
    echo "  带 Syslab 环境启动 VS Code："
    echo "      $CODE_CLI   （扩展宿主环境由 $TERM_ENV_KEY 提供；也可用 env.sh 后启动）"
fi
echo "  状态自检：~/.syslab-vscode/bridge-status.json（打开 .jl/.m 文件后写入）"
echo ""
echo "  提示：同元软控的 Syslab 扩展请勿公开上架到 VS Code Marketplace，仅限自有环境内部分发。"
