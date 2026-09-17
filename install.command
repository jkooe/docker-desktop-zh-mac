#!/bin/bash
#
# Docker Desktop 界面汉化 —— 安装脚本 (macOS)
#
# 用法：
#   在 Finder 中双击本文件；或在终端里执行 ./install.command
#
#   可选参数：
#     --yes        不再交互确认，直接执行
#     --force      即使检测到已汉化，也强制重新备份（危险，通常不需要）
#     --help       显示帮助
#
# 原理：
#   1. 备份官方 app.asar / Info.plist / app.asar.unpacked
#   2. 用上游 DDCS 脚本解包 app.asar，按开源翻译表替换界面文本，再重打包
#   3. 同步 Info.plist 中 ElectronAsarIntegrity 的哈希
#      （Docker Desktop 4.76.0+ 会校验该哈希，不同步会直接拒绝启动）
#
# 上游翻译表由 asxez/DDCS 提供（GPL-3.0），本脚本不包含其代码，运行时按需下载。
#

set -uo pipefail

# 双击运行时 cwd 是主目录，先切到脚本所在目录，保证相对路径可用。
cd "$(dirname "$0")" || exit 1

# shellcheck source=lib/common.sh
. "./lib/common.sh" || { echo "无法加载 lib/common.sh"; exit 1; }

FORCE=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --help|-h)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) printf '未知参数：%s\n' "$arg"; exit 2 ;;
  esac
done

ddz_title "Docker Desktop 界面汉化 (macOS)"

# ---------------------------------------------------------------------------
ddz_step "[1/7] 环境检查 ......"

if ! ddz_locate_docker; then
  ddz_fail "未找到 Docker Desktop"
  ddz_info ""
  ddz_info "  已查找：/Applications/Docker.app、~/Applications/Docker.app"
  ddz_info "  请先安装 Docker Desktop：https://www.docker.com/products/docker-desktop/"
  ddz_die
fi
ddz_ok "Docker Desktop：$DDZ_APP"

if [ ! -f "$DDZ_RES/app.asar" ]; then
  ddz_fail "未找到 $DDZ_RES/app.asar"
  ddz_info "  当前 Docker Desktop 的目录结构与脚本预期不符，请提 issue 并附上版本号。"
  ddz_die
fi

if ! ddz_find_tools; then
  ddz_die
fi
ddz_ok "python3：$DDZ_PY"
ddz_ok "node：$DDZ_NODE"

# DDCS 内部会用 subprocess 调 `node`，必须让它出现在 PATH 里。
export PATH="$(dirname "$DDZ_NODE"):$PATH"
[ -n "$DDZ_NPM" ] && PATH="$(dirname "$DDZ_NPM"):$PATH" && export PATH

# 权限探测：既要能改 Info.plist（文件），也要能替换 Resources 下的 app.asar（目录）
ddz_can_write_file "$DDZ_PLIST"; rc_plist=$?
if [ "$rc_plist" -eq 1 ]; then
  ddz_fail "当前终端没有修改 Docker.app 的权限"
  ddz_print_app_management_help
  ddz_die
elif [ "$rc_plist" -eq 2 ]; then
  ddz_fail "无法读写 $DDZ_PLIST"
  ddz_die
fi

ddz_can_write_dir "$DDZ_RES"; rc_dir=$?
if [ "$rc_dir" -ne 0 ]; then
  ddz_fail "当前终端没有在 Resources 目录内写入的权限"
  ddz_print_app_management_help
  ddz_die
fi
ddz_ok "写入权限正常"

ARCH="$(uname -m)"
ddz_ok "CPU 架构：$ARCH"

# ---------------------------------------------------------------------------
ddz_step "[2/7] 准备汉化工具链 ......"

if ! ddz_prepare_toolchain; then
  ddz_die
fi
DDZ_VENV_PY="$DDZ_VENV_DIR/bin/python3"

# ---------------------------------------------------------------------------
ddz_step "[3/7] 识别版本、当前状态与备份方案 ......"

VER="$(ddz_docker_version)"
ddz_ok "Docker Desktop 版本：$VER  (架构 $(uname -m))"

# --- 判据一：完整性（决定 Docker 能不能启动）---
INTEG="$(ddz_integrity_state)"
case "$INTEG" in
  consistent)
    ddz_ok "完整性校验：哈希一致，Electron 校验会通过" ;;
  inconsistent)
    ddz_warn "完整性校验：哈希不一致 —— Docker Desktop 现在应该起不来" ;;
  *)
    ddz_warn "完整性校验：无法判定（缺少 ElectronAsarIntegrity 字段，或 asar 工具异常）" ;;
esac

# --- 判据二：原版性（决定备份能不能用来回滚）---
# 注意：Docker 自身的校验哈希在汉化后会被同步，所以「哈希一致」并不等于「是原版」，
#       必须另外做文件指纹比对。
ORIG="$(ddz_originality)"
case "$ORIG" in
  original)
    ddz_ok "原版判定：app.asar 指纹与官方一致 —— 确认为官方原版" ;;
  localized)
    ddz_warn "原版判定：app.asar 指纹与官方不符 —— 已被改写（汉化过，或上次改动未完成）" ;;
  *)
    ddz_warn "原版判定：无法确认（官方指纹表中暂无 $VER / $(uname -m) 的记录）" ;;
esac

if [ "$VER" != "$DDZ_TABLE_VERSION" ]; then
  ddz_warn "翻译表是按 $DDZ_TABLE_VERSION 生成的，本机为 $VER"
  ddz_info "    版本不一致时，通常仍能汉化，但个别新增/改动过的界面可能显示异常。"
  ddz_info "    若启动后界面错乱，请先回滚：./restore.command"
  ddz_info "    上游按版本发布的成品包见：$DDZ_DDCS_HOME/releases"
fi

# ---- 先定备份方案，再决定要不要关 Docker（不满足条件就早退，不做无用功）----
EXISTING="$(ddz_find_original_backup)"
TS="$(date +%Y%m%d-%H%M%S)"
SAFE_LABEL="${VER:-unknown}-$TS"
BACKUP_DIR=""
DO_BACKUP=0
BACKUP_STATE="original"

case "$ORIG" in
  original)
    DO_BACKUP=1
    ;;
  unknown)
    if [ -n "$EXISTING" ]; then
      BACKUP_DIR="$EXISTING"
      ddz_ok "复用已有的原版备份：$EXISTING"
    else
      ddz_warn "无法确认当前 app.asar 是否为官方原版，将直接把当前文件备份下来"
      ddz_info ""
      ddz_info "  如果你从来没有改动过 Docker Desktop，这没问题。"
      ddz_info "  如果你此前用别的方式汉化过，这份备份就不是英文原版，回滚后仍是中文。"
      ddz_info ""
      if [ "$ASSUME_YES" -ne 1 ]; then
        printf '  确认当前是官方原版、继续？[y/N] '
        read -r a 2>/dev/null || a=""
        case "$a" in
          y|Y|yes|YES) ;;
          *) printf '\n已取消。建议先用 Docker 官方安装包重装一次。\n'; exit 0 ;;
        esac
      fi
      DO_BACKUP=1
      BACKUP_STATE="unknown"
    fi
    ;;
  localized|*)
    if [ -n "$EXISTING" ]; then
      BACKUP_DIR="$EXISTING"
      ddz_ok "复用已有的原版备份：$EXISTING"
      ddz_info "    不再重新备份，以免用「已汉化」的文件覆盖掉唯一的官方原版。"
    elif [ "$FORCE" -eq 1 ]; then
      DO_BACKUP=1
      BACKUP_STATE="forced"
      ddz_warn "--force：将以当前（已被改写的）文件生成备份"
      ddz_info "    这份备份不能用于回滚到英文原版。"
    else
      ddz_fail "当前安装已被改写，且找不到可用的官方原版备份，无法安全继续"
      ddz_info ""
      ddz_info "  两条路："
      ddz_info "    1) 用 Docker 官方安装包重装一次 Docker Desktop，恢复到原版后再运行本脚本；"
      ddz_info "    2) 确认你接受「用当前文件当备份」（将无法回滚到英文原版）："
      ddz_info "       ./install.command --force"
      ddz_die
    fi
    ;;
esac

# ---------------------------------------------------------------------------
ddz_step "[4/7] 关闭 Docker Desktop ......"

if [ "$ASSUME_YES" -ne 1 ]; then
  printf '即将关闭 Docker Desktop 并改写其安装文件，是否继续？[y/N] '
  read -r ans 2>/dev/null || ans=""
  case "$ans" in
    y|Y|yes|YES) ;;
    *) printf '\n已取消。\n'; exit 0 ;;
  esac
fi

if ! ddz_stop_docker; then
  ddz_fail "Docker Desktop 未能完全退出，请手动退出后重试"
  ddz_die
fi
ddz_ok "已关闭"

# ---------------------------------------------------------------------------
ddz_step "[5/7] 备份官方原版 ......"

if [ "$DO_BACKUP" -eq 1 ]; then
  BACKUP_DIR="$(ddz_make_backup "$SAFE_LABEL" "$BACKUP_STATE")" || { ddz_fail "备份失败"; ddz_die; }
  ddz_ok "已备份：$BACKUP_DIR  (STATE=$BACKUP_STATE)"
  if [ "$BACKUP_STATE" = "original" ]; then
    ddz_info "    回滚命令：./restore.command"
  else
    ddz_warn "此备份的 STATE=$BACKUP_STATE，不能保证可回滚到英文原版"
  fi
else
  ddz_ok "沿用已有备份，跳过备份步骤"
fi
ddz_info "    备份内 app.asar SHA256：$(ddz_sha256_file "$BACKUP_DIR/app-asar-backup.bin")"

# ---------------------------------------------------------------------------
ddz_step "[6/7] 执行汉化 ......"
ddz_info "  解包 → 替换文本 → 重打包 → 同步校验哈希"
ddz_info "  约需 1 分钟，请勿关闭窗口。"
printf '\n'

( cd "$DDZ_WORK_DIR" && "$DDZ_VENV_PY" ddcs.py ) 2>&1 | tail -n 25
DDCS_RC=${PIPESTATUS[0]}

printf '\n'
if [ "$DDCS_RC" -ne 0 ]; then
  ddz_fail "上游脚本返回非零退出码：$DDCS_RC"
  ddz_info "  若错误信息为「没有权限更新 macOS asar 完整性校验」，说明终端缺少「应用管理」授权。"
  ddz_print_app_management_help
  ddz_die
fi

# ---------------------------------------------------------------------------
ddz_step "[7/7] 校验并启动 ......"

RECORDED="$(ddz_plist_hash "$DDZ_PLIST")" || RECORDED=""
ACTUAL="$(ddz_asar_header_hash "$DDZ_RES/app.asar" "$DDZ_WORK_DIR")" || ACTUAL=""

if [ -z "$RECORDED" ] || [ -z "$ACTUAL" ]; then
  ddz_warn "无法读取校验值，跳过核对"
elif [ "$RECORDED" = "$ACTUAL" ]; then
  ddz_ok "完整性校验已同步"
  ddz_info "    Info.plist 记录：$RECORDED"
  ddz_info "    app.asar 实际： $ACTUAL"
else
  ddz_fail "完整性校验未同步，Docker Desktop 可能无法启动"
  ddz_info "    Info.plist 记录：$RECORDED"
  ddz_info "    app.asar 实际： $ACTUAL"
  ddz_info ""
  ddz_info "  请立即回滚：./restore.command"
  ddz_die
fi

ddz_info "    app.asar 文件哈希：$(ddz_sha256_file "$DDZ_RES/app.asar")"

# 上游重打包会顺带改掉 app.asar.unpacked/package.json（官方是 { "type": "commonjs" }），
# 顺手用备份把它改回官方版本，让 unpacked 目录与官方完全一致。
if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR/app.asar.unpacked" ]; then
  printf '\n'
  ddz_info "  修正 app.asar.unpacked（对齐官方原版）……"
  FIXED="$(ddz_sync_unpacked_from_backup "$BACKUP_DIR")"
  if [ "${FIXED:-0}" -eq 0 ]; then
    ddz_ok "无需修正"
  else
    ddz_ok "已修正 $FIXED 个文件"
  fi
fi

printf '\n'
ddz_start_docker

printf '\n'
ddz_rule
printf '  %s完成%s\n' "$DDZ_C_GRN" "$DDZ_C_RST"
ddz_rule
printf '\n'
ddz_info "  · 界面应显示为中文"
ddz_info "  · 若无法启动或界面异常，双击 restore.command 回滚"
ddz_info "  · Docker Desktop 每次自动更新后，汉化会被覆盖，重跑本脚本即可"
ddz_info "  · 官方原版备份位于：$BACKUP_DIR"
ddz_pause
