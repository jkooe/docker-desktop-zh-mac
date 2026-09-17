#!/bin/bash
#
# lib/common.sh —— 公共函数库
#
# 该文件被 install.command / restore.command / diagnose.command 以 source 方式加载，
# 不要直接执行它。
#
# 依赖：bash 3.2+（macOS 自带）、python3、node、curl、shasum
#

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

DDZ_DDCS_ZIP="https://github.com/asxez/DDCS/archive/refs/heads/master.zip"
DDZ_DDCS_HOME="https://github.com/asxez/DDCS"

# 翻译表是按某个确切版本生成的；版本不符时给出警告而不是硬失败。
DDZ_TABLE_VERSION="4.91.0"

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
  DDZ_C_RED=$'\033[31m'; DDZ_C_GRN=$'\033[32m'; DDZ_C_YEL=$'\033[33m'
  DDZ_C_CYN=$'\033[36m'; DDZ_C_BLD=$'\033[1m';  DDZ_C_RST=$'\033[0m'
else
  DDZ_C_RED=''; DDZ_C_GRN=''; DDZ_C_YEL=''; DDZ_C_CYN=''; DDZ_C_BLD=''; DDZ_C_RST=''
fi

ddz_info() { printf '%s\n' "$*"; }
ddz_ok()   { printf '  %s✓%s %s\n' "$DDZ_C_GRN" "$DDZ_C_RST" "$*"; }
ddz_warn() { printf '  %s!%s %s\n' "$DDZ_C_YEL" "$DDZ_C_RST" "$*"; }
ddz_fail() { printf '  %s✗%s %s\n' "$DDZ_C_RED" "$DDZ_C_RST" "$*"; }
ddz_step() { printf '\n%s%s%s\n' "$DDZ_C_BLD$DDZ_C_CYN" "$*" "$DDZ_C_RST"; }

ddz_rule() { printf '%s\n' "======================================================"; }
ddz_title() { ddz_rule; printf '  %s\n' "$*"; ddz_rule; printf '\n'; }

# 双击运行时窗口会在脚本结束后立刻消失，需要一个停顿点。
ddz_pause() {
  printf '\n按回车键关闭窗口。'
  read -r _ 2>/dev/null || true
}

ddz_die() {
  printf '\n'
  ddz_rule
  printf '  %s已中止%s\n' "$DDZ_C_RED" "$DDZ_C_RST"
  ddz_rule
  ddz_pause
  exit 1
}

# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------

# resolve_dir <path> —— 解析出绝对路径（不要求真实存在）
ddz_resolve_dir() {
  local d="$1"
  ( cd "$d" 2>/dev/null && pwd ) || printf '%s\n' "$d"
}

# 项目根目录（lib/ 的上一级）。双击 .command 时 cwd 是用户主目录，必须靠 $0 定位。
DDZ_LIB_DIR="$(ddz_resolve_dir "$(dirname "${BASH_SOURCE[0]}")")"
DDZ_PROJECT_DIR="$(ddz_resolve_dir "$DDZ_LIB_DIR/..")"

DDZ_WORK_DIR="$DDZ_PROJECT_DIR/.ddcs"        # 上游源码 + node_modules（gitignore）
DDZ_VENV_DIR="$DDZ_PROJECT_DIR/.venv"        # Python 虚拟环境（gitignore）
DDZ_BACKUP_ROOT="$DDZ_PROJECT_DIR/backups"   # 官方原版备份（gitignore）

# 定位 Docker Desktop。返回 0 表示成功，并设置 DDZ_APP 等变量。
DDZ_APP=""
DDZ_INNER_APP=""
DDZ_RES=""
DDZ_PLIST=""

ddz_locate_docker() {
  local candidates=()
  # 允许覆盖安装位置（非标准路径 / 同时装有多份时使用）
  [ -n "${DDZ_DOCKER_APP:-}" ] && candidates+=("${DDZ_DOCKER_APP%/}")
  candidates+=(
    "/Applications/Docker.app"
    "$HOME/Applications/Docker.app"
  )
  local app
  for app in "${candidates[@]}"; do
    if [ -d "$app/Contents/MacOS/Docker Desktop.app" ]; then
      DDZ_APP="$app"
      DDZ_INNER_APP="$app/Contents/MacOS/Docker Desktop.app"
      DDZ_RES="$DDZ_INNER_APP/Contents/Resources"
      DDZ_PLIST="$DDZ_INNER_APP/Contents/Info.plist"
      return 0
    fi
  done

  # 兜底：用 Spotlight 找（仅当没有显式覆盖时）
  if [ -z "${DDZ_DOCKER_APP:-}" ]; then
    local found
    found="$(mdfind -name 'Docker.app' 2>/dev/null | grep -m1 '/Docker\.app$' || true)"
    if [ -n "$found" ] && [ -d "$found/Contents/MacOS/Docker Desktop.app" ]; then
      DDZ_APP="$found"
      DDZ_INNER_APP="$found/Contents/MacOS/Docker Desktop.app"
      DDZ_RES="$DDZ_INNER_APP/Contents/Resources"
      DDZ_PLIST="$DDZ_INNER_APP/Contents/Info.plist"
      return 0
    fi
  fi
  return 1
}

# ---------------------------------------------------------------------------
# 外部工具探测
# ---------------------------------------------------------------------------

DDZ_PY=""
DDZ_NODE=""
DDZ_NPM=""

ddz_find_tools() {
  local missing=()

  # ---- python3（需要 >= 3.8）----
  local p
  for p in "$(command -v python3 2>/dev/null || true)" /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    [ -n "$p" ] && [ -x "$p" ] || continue
    if "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
      DDZ_PY="$p"; break
    fi
  done
  [ -n "$DDZ_PY" ] || missing+=("python3 (>= 3.8)")

  # ---- node ----
  local n
  for n in "$(command -v node 2>/dev/null || true)" /opt/homebrew/bin/node /usr/local/bin/node; do
    [ -n "$n" ] && [ -x "$n" ] || continue
    DDZ_NODE="$n"; break
  done
  [ -n "$DDZ_NODE" ] || missing+=("node")

  # ---- npm（仅首次准备时需要）----
  local m
  for m in "$(command -v npm 2>/dev/null || true)" /opt/homebrew/bin/npm /usr/local/bin/npm; do
    [ -n "$m" ] && [ -x "$m" ] || continue
    DDZ_NPM="$m"; break
  done

  if [ ${#missing[@]} -gt 0 ]; then
    ddz_fail "缺少必需工具：${missing[*]}"
    ddz_info ""
    ddz_info "  安装方式（任选其一）："
    ddz_info "    · 已装 Homebrew：brew install python node"
    ddz_info "    · 官方安装包：https://www.python.org/downloads/macos/"
    ddz_info "                  https://nodejs.org/zh-cn/download"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 版本与哈希
# ---------------------------------------------------------------------------

ddz_docker_version() {
  [ -n "$DDZ_APP" ] || return 1
  defaults read "$DDZ_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null
}

# app.asar 的 Electron 完整性哈希 = asar 头部 JSON 的 SHA256（不是整包 SHA256）。
# 必须在含 node_modules/asar 的目录下调用 node 才能解析 require('asar/lib/disk')。
ddz_asar_header_hash() {
  local asar="$1" dir="${2:-$DDZ_WORK_DIR}"
  [ -f "$asar" ] || return 1
  [ -n "$DDZ_NODE" ] || return 1
  ( cd "$dir" 2>/dev/null || exit 1
    "$DDZ_NODE" -e "const disk=require('asar/lib/disk');const crypto=require('crypto');const h=disk.readArchiveHeaderSync(process.argv[1]).header;process.stdout.write(crypto.createHash('sha256').update(JSON.stringify(h)).digest('hex'));" "$asar" 2>/dev/null
  ) | tr -d '\n'
}

# Info.plist 里记录的 ElectronAsarIntegrity['Resources/app.asar'].hash
ddz_plist_hash() {
  local plist="$1"
  [ -f "$plist" ] || return 1
  "$DDZ_PY" - "$plist" <<'PYEOF' 2>/dev/null
import plistlib, sys
try:
    d = plistlib.load(open(sys.argv[1], "rb"))
except Exception:
    sys.exit(1)
integ = d.get("ElectronAsarIntegrity")
if not isinstance(integ, dict):
    sys.exit(1)
key = next((k for k in integ if k.lower() == "resources/app.asar"), None)
if key is None:
    sys.exit(1)
entry = integ.get(key)
if not isinstance(entry, dict):
    sys.exit(1)
h = entry.get("hash")
if not h:
    sys.exit(1)
sys.stdout.write(h)
PYEOF
}

ddz_sha256_file() {
  shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
}

# 当前安装的「完整性」状态：
#   consistent    Info.plist 记录的哈希 == app.asar 实际哈希 → Electron 校验会通过，能启动
#   inconsistent  两者不一致 → Electron 会拒绝启动
#   unknown       缺少工具或字段，无法判定
#
# 注意：consistent 只说明「内部自洽」，不能说明「这是官方原版」——
#       汉化成功后哈希会被同步，因此同样 consistent。判断原版请看 ddz_originality。
ddz_integrity_state() {
  local recorded actual
  recorded="$(ddz_plist_hash "$DDZ_PLIST")" || true
  actual="$(ddz_asar_header_hash "$DDZ_RES/app.asar")" || true
  if [ -z "$recorded" ] || [ -z "$actual" ]; then
    printf 'unknown'; return
  fi
  if [ "$recorded" = "$actual" ]; then
    printf 'consistent'
  else
    printf 'inconsistent'
  fi
}

# 查官方指纹表：ddz_official_sha_lockup <版本> <架构>，命中则输出 SHA256
ddz_official_sha_lookup() {
  local ver="$1" arch="$2" tbl="$DDZ_PROJECT_DIR/data/official-asar-sha256.txt"
  [ -f "$tbl" ] || return 1
  awk -v v="$ver" -v a="$arch" '
    /^[[:space:]]*#/ { next }
    NF >= 3 && $1 == v && $2 == a { print $3; found = 1; exit }
    END { if (!found) exit 1 }
  ' "$tbl" 2>/dev/null
}

# 判定当前 app.asar 是否为「未改动的官方原版」：
#   original   与官方指纹表或原版备份指纹吻合 → 是原版
#   localized  与已知原版指纹不符 → 已被改写（很可能是汉化版）
#   unknown    没有可比对的基准
ddz_originality() {
  local f="$DDZ_RES/app.asar"
  [ -f "$f" ] || { printf 'unknown'; return; }

  local cur
  cur="$(ddz_sha256_file "$f")"
  [ -n "$cur" ] || { printf 'unknown'; return; }

  # 基准 1：官方指纹表
  local official
  official="$(ddz_official_sha_lookup "$(ddz_docker_version)" "$(uname -m)")" || official=""
  if [ -n "$official" ]; then
    if [ "$cur" = "$official" ]; then printf 'original'; else printf 'localized'; fi
    return
  fi

  # 基准 2：已有的原版备份
  local b
  b="$(ddz_find_original_backup)"
  if [ -n "$b" ] && [ -f "$b/app-asar-backup.bin" ]; then
    if [ "$cur" = "$(ddz_sha256_file "$b/app-asar-backup.bin")" ]; then
      printf 'original'
    else
      printf 'localized'
    fi
    return
  fi

  printf 'unknown'
}

# ---------------------------------------------------------------------------
# 权限（macOS TCC「应用管理」）
# ---------------------------------------------------------------------------

# 返回 0=可写，1=没有权限，2=其他错误（文件不存在等）
ddz_can_write_file() {
  local f="$1"
  "$DDZ_PY" - "$f" <<'PYEOF'
import sys
try:
    with open(sys.argv[1], "r+b"):
        pass
except PermissionError:
    sys.exit(1)
except Exception:
    sys.exit(2)
sys.exit(0)
PYEOF
}

ddz_can_write_dir() {
  local d="$1" probe
  [ -d "$d" ] || return 2
  probe="$d/.ddz-write-probe-$$"
  if mkdir "$probe" 2>/dev/null; then
    rmdir "$probe" 2>/dev/null || true
    return 0
  fi
  return 1
}

ddz_print_app_management_help() {
  local plist="${DDZ_PLIST:-/Applications/Docker.app/Contents/MacOS/Docker Desktop.app/Contents/Info.plist}"
  ddz_info ""
  ddz_info "  macOS 需要「应用管理」权限，才允许终端改写其他 App 包内的文件。"
  ddz_info "  这是系统隐私保护（TCC），不是文件权限问题：文件属主、标志位、ACL 都是正常的。"
  ddz_info ""
  ddz_info "  授权步骤（一次性）："
  ddz_info "    1. 打开「系统设置」"
  ddz_info "    2. 进入「隐私与安全性」→「应用管理」"
  ddz_info "    3. 找到你正在使用的终端（终端 / iTerm / VS Code …）并打开右侧开关"
  ddz_info "    4. 按 ⌘Q 完全退出该终端，再重新打开"
  ddz_info "    5. 重新运行本脚本"
  ddz_info ""
  ddz_info "  若「应用管理」列表里找不到你的终端，先执行下面这行以触发系统弹窗："
  ddz_info "    touch \"$plist\""
  ddz_info "  在弹窗里点「好」，再回到上面的位置打开开关。"
}

# ---------------------------------------------------------------------------
# Docker 进程控制
# ---------------------------------------------------------------------------

ddz_stop_docker() {
  osascript -e 'quit app "Docker"' >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 40); do
    pgrep -f "Docker Desktop" >/dev/null 2>&1 || break
    sleep 1
  done
  if pgrep -f "Docker Desktop" >/dev/null 2>&1; then
    ddz_warn "仍在运行，强制结束 ......"
    pkill -f "Docker Desktop" >/dev/null 2>&1 || true
    sleep 3
  fi
  if pgrep -f "Docker Desktop" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

ddz_start_docker() {
  open -a "${DDZ_APP:-/Applications/Docker.app}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 备份
# ---------------------------------------------------------------------------

# 找出一份已存在的、内容为官方原版的备份目录；找不到则输出空。
# 判定依据：备份目录里有 STATE 文件且写着 original。
ddz_find_original_backup() {
  [ -d "$DDZ_BACKUP_ROOT" ] || return 0
  local d
  for d in $(ls -1dt "$DDZ_BACKUP_ROOT"/*/ 2>/dev/null); do
    if [ -f "${d}STATE" ] && [ "$(cat "${d}STATE" 2>/dev/null)" = "original" ] \
       && [ -f "${d}app-asar-backup.bin" ]; then
      printf '%s\n' "${d%/}"
      return 0
    fi
  done
  return 0
}

# 写一份完整备份。$1 = 标签（用于目录名），$2 = 状态标记（original / forced）
ddz_make_backup() {
  local label="$1" state="${2:-original}" dest="$DDZ_BACKUP_ROOT/$label"
  mkdir -p "$dest" || return 1

  cp "$DDZ_RES/app.asar" "$dest/app-asar-backup.bin" || return 1
  cp "$DDZ_PLIST"        "$dest/Info.plist"            || return 1
  rm -rf "$dest/app.asar.unpacked"
  cp -R "$DDZ_RES/app.asar.unpacked" "$dest/app.asar.unpacked" || return 1

  # 用 .bin 扩展名保存 asar：某些沙箱/同步工具会拦截 .asar 写入，
  # 同时也能避免 macOS 把它当成可执行归档处理。
  {
    printf '%s\n' "$(ddz_docker_version)"                 > "$dest/VERSION"
    printf '%s\n' "$state"                                 > "$dest/STATE"
    printf '%s\n' "created $(date '+%Y-%m-%d %H:%M:%S')"   > "$dest/INFO"
  } 2>/dev/null

  shasum -a 256 "$dest/app-asar-backup.bin" "$dest/Info.plist" > "$dest/SHA256SUMS.txt" 2>/dev/null
  printf '%s\n' "$dest"
}

# ---------------------------------------------------------------------------
# 上游工具链准备
# ---------------------------------------------------------------------------

ddz_prepare_toolchain() {
  mkdir -p "$DDZ_WORK_DIR" || return 1

  # 1) 拉取 DDCS 源码
  if [ ! -f "$DDZ_WORK_DIR/ddcs.py" ]; then
    ddz_info "  · 首次运行，正在获取上游汉化脚本 ……"
    local tmp="$DDZ_WORK_DIR/_src.zip"
    local curl_args=(-fL --retry 3 --connect-timeout 20 -o "$tmp")
    [ -n "${DDZ_PROXY:-}" ] && curl_args=(--proxy "$DDZ_PROXY" "${curl_args[@]}")
    if ! curl "${curl_args[@]}" "$DDZ_DDCS_ZIP"; then
      ddz_fail "下载失败：$DDZ_DDCS_ZIP"
      ddz_info ""
      ddz_info "  如果所在网络访问 GitHub 受限，请先设置代理再重试，例如："
      ddz_info "    export DDZ_PROXY=http://127.0.0.1:7890"
      ddz_info "  （curl 也会自动读取 https_proxy / HTTPS_PROXY 环境变量）"
      return 1
    fi
    ( cd "$DDZ_WORK_DIR" && unzip -q -o _src.zip ) || { ddz_fail "解压失败"; return 1; }
    rm -f "$tmp"
    # 压缩包解出的是 DDCS-master/，把内容提到 .ddcs/ 下
    if [ -d "$DDZ_WORK_DIR/DDCS-master" ]; then
      local f
      for f in "$DDZ_WORK_DIR"/DDCS-master/* "$DDZ_WORK_DIR"/DDCS-master/.[!.]*; do
        [ -e "$f" ] || continue
        mv "$f" "$DDZ_WORK_DIR/" 2>/dev/null || true
      done
      rmdir "$DDZ_WORK_DIR/DDCS-master" 2>/dev/null || true
    fi
    [ -f "$DDZ_WORK_DIR/ddcs.py" ] || { ddz_fail "上游脚本结构异常，未找到 ddcs.py"; return 1; }
    ddz_ok "上游脚本已就位：$DDZ_WORK_DIR"
  else
    ddz_ok "上游脚本已存在：$DDZ_WORK_DIR"
  fi

  # 2) Python 虚拟环境（DDCS 只需要标准库，venv 保证隔离、不污染系统）
  if [ ! -x "$DDZ_VENV_DIR/bin/python3" ]; then
    ddz_info "  · 正在创建 Python 虚拟环境 ……"
    "$DDZ_PY" -m venv "$DDZ_VENV_DIR" || { ddz_fail "创建虚拟环境失败（$DDZ_PY -m venv）"; return 1; }
  fi
  DDZ_VENV_PY="$DDZ_VENV_DIR/bin/python3"

  # 3) asar 命令行（局部安装，不用 npm -g）
  if [ ! -x "$DDZ_WORK_DIR/node_modules/.bin/asar" ]; then
    if [ -z "$DDZ_NPM" ]; then
      ddz_fail "未找到 npm，无法安装 asar（装完 Node.js 后重试）"
      return 1
    fi
    ddz_info "  · 正在安装 asar（局部依赖，约几 MB）……"
    local npm_args=(--silent --no-fund --no-audit)
    [ -n "${DDZ_PROXY:-}" ] && npm_args+=(--proxy "$DDZ_PROXY" --https-proxy "$DDZ_PROXY")
    local asar_spec
    asar_spec="$(ddz_resolve_asar_spec)"
    ( cd "$DDZ_WORK_DIR" && "$DDZ_NPM" install "${npm_args[@]}" "$asar_spec" ) \
      || { ddz_fail "asar 安装失败"; return 1; }
  fi
  if [ ! -x "$DDZ_WORK_DIR/node_modules/.bin/asar" ]; then
    ddz_fail "asar 仍未就绪"
    return 1
  fi
  ddz_ok "asar 已就绪"
  return 0
}

# 优先使用上游 package.json 里声明的 asar 版本，保证行为一致。
ddz_resolve_asar_spec() {
  local pkg="$DDZ_WORK_DIR/package.json" spec=""
  if [ -f "$pkg" ]; then
    spec="$("$DDZ_PY" - "$pkg" <<'PYEOF' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
deps = {}
deps.update(d.get("dependencies") or {})
deps.update(d.get("devDependencies") or {})
v = deps.get("asar")
if v:
    sys.stdout.write("asar@" + str(v).lstrip("^~"))
PYEOF
)"
  fi
  printf '%s\n' "${spec:-asar@3.2.0}"
}

# ---------------------------------------------------------------------------
# 修正 app.asar.unpacked
# ---------------------------------------------------------------------------

# 上游重打包时会顺手把 app/package.json 一并 unpack，覆盖掉官方原先放在
# app.asar.unpacked/package.json 的标记文件 { "type": "commonjs" }。
# 结果是：该目录下的 .js 会被 Node 按 ESM 解析，而官方原意是 CommonJS。
# 实测 4.91.0 没出问题，但这是个可以顺手消除的隐患。
#
# 做法：拿备份里的官方 unpacked 目录逐文件比对，把不同的文件覆盖回去。
# 只动「内容不同」的文件，不动清单结构。
#
# $1 = 备份目录   $2 = dry-run（可选，传 --dry-run 则只报告不修改）
# 输出：需要/已修正的文件数
ddz_sync_unpacked_from_backup() {
  local bak="$1/app.asar.unpacked" cur="$DDZ_RES/app.asar.unpacked"
  local dry="$2"
  [ -d "$bak" ] || { printf '0'; return 0; }
  [ -d "$cur" ] || { printf '0'; return 0; }

  local changed=0 rel
  while IFS= read -r -d '' rel; do
    rel="${rel#./}"
    if [ ! -f "$cur/$rel" ] || ! cmp -s "$bak/$rel" "$cur/$rel"; then
      changed=$((changed + 1))
      # 注意：这些提示必须走 stderr，否则会被调用方的 $( ) 当成返回值捕获。
      if [ "$dry" != "--dry-run" ]; then
        mkdir -p "$(dirname "$cur/$rel")" 2>/dev/null
        cp -p "$bak/$rel" "$cur/$rel" 2>/dev/null || true
        ddz_info "      修正：$rel" >&2
      else
        ddz_info "      待修正：$rel" >&2
      fi
    fi
  done < <(cd "$bak" && find . -type f -print0 2>/dev/null)

  printf '%s' "$changed"
}
