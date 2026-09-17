#!/bin/bash
#
# Docker Desktop 界面汉化 —— 回滚脚本 (macOS)
#
# 用法：
#   在 Finder 中双击本文件；或在终端里执行 ./restore.command
#
#   可选参数：
#     --list            只列出所有备份，不做任何修改
#     --from <目录>     指定使用某个备份目录
#     --yes             不再交互确认
#     --help            显示帮助
#
# 作用：把 Docker Desktop 还原为官方原版（英文界面），
#       使用 install.command 在汉化前备份的原始文件。
#

set -uo pipefail

cd "$(dirname "$0")" || exit 1

# shellcheck source=lib/common.sh
. "./lib/common.sh" || { echo "无法加载 lib/common.sh"; exit 1; }

FROM_DIR=""
ASSUME_YES=0
LIST_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --list|-l) LIST_ONLY=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --from) shift; FROM_DIR="${1:-}" ;;
    --help|-h) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf '未知参数：%s\n' "$1"; exit 2 ;;
  esac
  shift
done

ddz_title "Docker Desktop 还原为官方原版"

# ---------------------------------------------------------------------------
ddz_step "[1/5] 列出可用备份 ......"

if [ ! -d "$DDZ_BACKUP_ROOT" ]; then
  ddz_fail "备份目录不存在：$DDZ_BACKUP_ROOT"
  ddz_info "  说明本机从未用本工具做过汉化，或备份已被删除。"
  ddz_info "  若界面当前是中文，重装 Docker Desktop 即可恢复原版。"
  ddz_die
fi

declare -a CANDIDATES=()
for d in $(ls -1dt "$DDZ_BACKUP_ROOT"/*/ 2>/dev/null); do
  d="${d%/}"
  [ -f "$d/app-asar-backup.bin" ] || continue
  st="$(cat "$d/STATE" 2>/dev/null || echo '?')"
  ver="$(cat "$d/VERSION" 2>/dev/null || echo '?')"
  sz="$(stat -f %z "$d/app-asar-backup.bin" 2>/dev/null || echo 0)"
  mark=" "
  [ "$st" = "original" ] && mark="*"
  printf '  %s %s  (Docker %s, %s 字节, STATE=%s)\n' "$mark" "$(basename "$d")" "$ver" "$sz" "$st"
  CANDIDATES+=("$d")
done

if [ ${#CANDIDATES[@]} -eq 0 ]; then
  ddz_fail "备份目录中没有可用的备份"
  ddz_die
fi
printf '\n'
ddz_info "  带 * 的是官方原版备份（推荐用它回滚）"

if [ "$LIST_ONLY" -eq 1 ]; then
  printf '\n'
  exit 0
fi

# ---------------------------------------------------------------------------
ddz_step "[2/5] 选择备份 ......"

TARGET=""
if [ -n "$FROM_DIR" ]; then
  if [ -d "$FROM_DIR" ] && [ -f "$FROM_DIR/app-asar-backup.bin" ]; then
    TARGET="$FROM_DIR"
  else
    ddz_fail "指定的备份不可用：$FROM_DIR"
    ddz_die
  fi
else
  # 优先选最新的原版备份
  TARGET="$(ddz_find_original_backup)"
  if [ -z "$TARGET" ]; then
    ddz_warn "没有标记为 original 的原版备份，将使用最新的一份"
    TARGET="${CANDIDATES[0]}"
  fi
fi
ddz_ok "使用备份：$TARGET"

SRC_BIN="$TARGET/app-asar-backup.bin"
SRC_PLIST="$TARGET/Info.plist"
SRC_UNPACKED="$TARGET/app.asar.unpacked"

[ -f "$SRC_BIN" ]   || { ddz_fail "缺少 app-asar-backup.bin"; ddz_die; }
[ -f "$SRC_PLIST" ] || { ddz_fail "缺少 Info.plist"; ddz_die; }
[ -d "$SRC_UNPACKED" ] || { ddz_fail "缺少 app.asar.unpacked/"; ddz_die; }

# 备份完整性自检
if [ -f "$TARGET/SHA256SUMS.txt" ]; then
  if ( cd "$TARGET" && shasum -a 256 -c SHA256SUMS.txt >/dev/null 2>&1 ); then
    ddz_ok "备份自检通过（SHA256SUMS.txt）"
  else
    ddz_warn "备份自检未通过：文件与 SHA256SUMS.txt 不一致"
    printf '    仍要继续吗？[y/N] '
    read -r a 2>/dev/null || a=""
    case "$a" in y|Y) ;; *) printf '\n已取消。\n'; exit 0 ;; esac
  fi
fi
ddz_info "    原版 app.asar SHA256：$(ddz_sha256_file "$SRC_BIN")"

# ---------------------------------------------------------------------------
ddz_step "[3/5] 检查权限 ......"

if ! ddz_locate_docker; then
  ddz_fail "未找到 Docker Desktop"
  ddz_die
fi
ddz_ok "Docker Desktop：$DDZ_APP"

if ! ddz_find_tools; then
  # 回滚其实只用到 python3（权限探测），缺 node 也不算致命
  if [ -z "$DDZ_PY" ]; then
    ddz_fail "缺少 python3，无法进行权限探测"
    ddz_die
  fi
  ddz_warn "node 不可用，不影响回滚"
fi

ddz_can_write_file "$DDZ_PLIST"; rc=$?
if [ "$rc" -eq 1 ]; then
  ddz_fail "当前终端没有修改 Docker.app 的权限"
  ddz_print_app_management_help
  ddz_die
elif [ "$rc" -eq 2 ]; then
  ddz_fail "无法读写 $DDZ_PLIST"
  ddz_die
fi
ddz_can_write_dir "$DDZ_RES"; rc=$?
if [ "$rc" -ne 0 ]; then
  ddz_fail "当前终端没有在 Resources 目录内写入的权限"
  ddz_print_app_management_help
  ddz_die
fi
ddz_ok "写入权限正常"

# ---------------------------------------------------------------------------
ddz_step "[4/5] 关闭 Docker Desktop 并恢复文件 ......"

if [ "$ASSUME_YES" -ne 1 ]; then
  printf '即将用备份覆盖当前安装（界面会变回英文），是否继续？[y/N] '
  read -r ans 2>/dev/null || ans=""
  case "$ans" in y|Y|yes|YES) ;; *) printf '\n已取消。\n'; exit 0 ;; esac
fi

if ! ddz_stop_docker; then
  ddz_fail "Docker Desktop 未能完全退出，请手动退出后重试"
  ddz_die
fi
ddz_ok "已关闭"

cp "$SRC_BIN" "$DDZ_RES/app.asar" || { ddz_fail "恢复 app.asar 失败"; ddz_die; }
ddz_ok "已恢复 app.asar"

rm -rf "$DDZ_RES/app.asar.unpacked" || { ddz_fail "清理 app.asar.unpacked 失败"; ddz_die; }
cp -R "$SRC_UNPACKED" "$DDZ_RES/app.asar.unpacked" || { ddz_fail "恢复 app.asar.unpacked 失败"; ddz_die; }
ddz_ok "已恢复 app.asar.unpacked"

cp "$SRC_PLIST" "$DDZ_PLIST" || { ddz_fail "恢复 Info.plist 失败"; ddz_die; }
ddz_ok "已恢复 Info.plist"

# ---------------------------------------------------------------------------
ddz_step "[5/5] 校验并启动 ......"

NEW_SHA="$(ddz_sha256_file "$DDZ_RES/app.asar")"
ddz_info "    恢复后 app.asar SHA256：$NEW_SHA"

if [ -n "$DDZ_NODE" ] && [ -x "$DDZ_WORK_DIR/node_modules/.bin/asar" ]; then
  RECORDED="$(ddz_plist_hash "$DDZ_PLIST")" || RECORDED=""
  ACTUAL="$(ddz_asar_header_hash "$DDZ_RES/app.asar" "$DDZ_WORK_DIR")" || ACTUAL=""
  if [ -n "$RECORDED" ] && [ "$RECORDED" = "$ACTUAL" ]; then
    ddz_ok "完整性校验一致，已回到官方原版"
  else
    ddz_warn "校验值不一致（可能备份本身即为非原版）"
    ddz_info "    Info.plist：$RECORDED"
    ddz_info "    app.asar：  $ACTUAL"
  fi
else
  ddz_info "    （asar 工具不可用，跳过完整性核对）"
fi

printf '\n'
ddz_start_docker

printf '\n'
ddz_rule
printf '  %s完成%s\n' "$DDZ_C_GRN" "$DDZ_C_RST"
ddz_rule
ddz_pause
