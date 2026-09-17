#!/bin/bash
#
# Docker Desktop 界面汉化 —— 环境诊断脚本 (macOS)
#
# 用法：
#   在 Finder 中双击本文件；或在终端里执行 ./diagnose.command
#
# 本脚本只做检查与报告，不改动任何文件（权限探测会临时建一个探针目录并立即删除）。
# 遇到问题、要提 issue 时，请把本脚本的完整输出贴上去。
#

set -uo pipefail

cd "$(dirname "$0")" || exit 1

# shellcheck source=lib/common.sh
. "./lib/common.sh" || { echo "无法加载 lib/common.sh"; exit 1; }

ddz_title "Docker Desktop 汉化环境诊断"

# ---------------------------------------------------------------------------
ddz_step "[1/6] 系统信息 ......"
ddz_info "  · 时间：$(date '+%Y-%m-%d %H:%M:%S')"
ddz_info "  · 系统：macOS $(sw_vers -productVersion 2>/dev/null || echo '?')  ($(sw_vers -buildVersion 2>/dev/null || echo '?'))"
ddz_info "  · 架构：$(uname -m)"
ddz_info "  · 用户：$(whoami)"
ddz_info "  · 项目目录：$DDZ_PROJECT_DIR"

# ---------------------------------------------------------------------------
ddz_step "[2/6] 定位 Docker Desktop ......"
if ddz_locate_docker; then
  ddz_ok "安装路径：$DDZ_APP"
  ddz_info "    内部路径：$DDZ_INNER_APP"
  ddz_info "    资源目录：$DDZ_RES"
  ddz_info "    版本：$(ddz_docker_version)  (翻译表对应版本：$DDZ_TABLE_VERSION)"
  [ -f "$DDZ_PLIST" ] && ddz_ok "Info.plist 存在" || ddz_fail "Info.plist 不存在"
  [ -f "$DDZ_RES/app.asar" ] && ddz_ok "app.asar 存在" || ddz_fail "app.asar 不存在"
  [ -d "$DDZ_RES/app.asar.unpacked" ] && ddz_ok "app.asar.unpacked 存在" || ddz_warn "app.asar.unpacked 不存在"
else
  ddz_fail "未找到 Docker Desktop"
  ddz_info "  已查找：/Applications/Docker.app、~/Applications/Docker.app"
fi

# ---------------------------------------------------------------------------
ddz_step "[3/6] 工具链 ......"
if ddz_find_tools; then
  ddz_ok "python3：$DDZ_PY  ($("$DDZ_PY" -V 2>&1))"
  ddz_ok "node：   $DDZ_NODE  ($("$DDZ_NODE" -v 2>&1))"
  if [ -n "$DDZ_NPM" ]; then
    ddz_ok "npm：    $DDZ_NPM  ($("$DDZ_NPM" -v 2>&1))"
  else
    ddz_warn "npm：未找到（首次安装时需要）"
  fi
else
  ddz_fail "缺少 python3 或 node，详见下方提示"
fi

[ -f "$DDZ_WORK_DIR/ddcs.py" ] && ddz_ok "上游脚本：已就位 ($DDZ_WORK_DIR)" \
                               || ddz_warn "上游脚本：未下载（首次运行 install.command 时会自动获取）"
[ -x "$DDZ_VENV_DIR/bin/python3" ] && ddz_ok "虚拟环境：已就位" || ddz_warn "虚拟环境：未创建"
[ -x "$DDZ_WORK_DIR/node_modules/.bin/asar" ] && ddz_ok "asar：已就位" || ddz_warn "asar：未安装"

# ---------------------------------------------------------------------------
ddz_step "[4/6] 写入权限 ......"
ddz_info "  （macOS「应用管理」TCC 权限；不看权限位，而是真实试写）"
if [ -n "$DDZ_PY" ] && [ -f "$DDZ_PLIST" ]; then
  ddz_can_write_file "$DDZ_PLIST"; rc_file=$?
  case "$rc_file" in
    0) ddz_ok "Info.plist 可写" ;;
    1) ddz_fail "Info.plist 不可写 —— 缺少「应用管理」授权" ;;
    *) ddz_warn "Info.plist 读取异常" ;;
  esac

  ddz_can_write_dir "$DDZ_RES"; rc_dir=$?
  case "$rc_dir" in
    0) ddz_ok "Resources 目录可写" ;;
    1) ddz_fail "Resources 目录不可写 —— 缺少「应用管理」授权" ;;
    *) ddz_warn "Resources 目录读取异常" ;;
  esac

  # 注意：不要用 `[ -w file ]` 判断——TCC 拦截时它仍然返回真，会误导排查。
  if [ "$rc_file" -eq 1 ] || [ "$rc_dir" -eq 1 ]; then
    ddz_print_app_management_help
  fi
else
  ddz_warn "跳过（缺少 python3 或找不到 Info.plist）"
fi

# ---------------------------------------------------------------------------
ddz_step "[5/6] 安装状态 ......"

if [ -f "$DDZ_RES/app.asar" ]; then
  ddz_info "  · 文件大小：$(stat -f %z "$DDZ_RES/app.asar" 2>/dev/null) 字节"
  ddz_info "  · 文件 SHA256：$(ddz_sha256_file "$DDZ_RES/app.asar")"

  RECORDED="$(ddz_plist_hash "$DDZ_PLIST")" || RECORDED=""
  ACTUAL="$(ddz_asar_header_hash "$DDZ_RES/app.asar" "$DDZ_WORK_DIR")" || ACTUAL=""

  # --- 判据一：完整性（决定能不能启动）---
  ddz_info ""
  ddz_info "  【完整性】决定 Docker Desktop 能否启动"
  if [ -z "$RECORDED" ]; then
    ddz_warn "Info.plist 中没有读到 ElectronAsarIntegrity 记录"
  else
    ddz_info "    Info.plist 记录：$RECORDED"
  fi
  if [ -z "$ACTUAL" ]; then
    ddz_warn "无法计算 app.asar 头部哈希（需要 asar 工具，先运行一次 install.command）"
  else
    ddz_info "    app.asar 实际：  $ACTUAL"
  fi

  INTEG="$(ddz_integrity_state)"
  case "$INTEG" in
    consistent)
      ddz_ok "两者一致 —— 校验会通过" ;;
    inconsistent)
      ddz_fail "两者不一致 —— Electron 会拒绝启动"
      ddz_info "      处理：./restore.command 回滚，或重跑 ./install.command 以同步校验值" ;;
    *)
      ddz_warn "无法判定" ;;
  esac

  # --- 判据二：原版性（决定备份能不能用来回滚）---
  ddz_info ""
  ddz_info "  【原版性】决定备份能否用于回滚到英文原版"
  OFFICIAL="$(ddz_official_sha_lookup "$(ddz_docker_version)" "$(uname -m)")" || OFFICIAL=""
  if [ -n "$OFFICIAL" ]; then
    ddz_info "    官方指纹（表内）：$OFFICIAL"
  else
    ddz_info "    官方指纹（表内）：无 $(ddz_docker_version) / $(uname -m) 的记录"
  fi
  case "$(ddz_originality)" in
    original)  ddz_ok "指纹与官方一致 —— 是官方原版" ;;
    localized) ddz_warn "指纹与官方不符 —— 已被改写（汉化过）" ;;
    *)         ddz_warn "无法判定 —— 指纹表中缺少该版本记录，且本地没有原版备份可比对" ;;
  esac
fi

ddz_info ""
if pgrep -f "Docker Desktop" >/dev/null 2>&1; then
  ddz_info "  · Docker Desktop：运行中"
else
  ddz_info "  · Docker Desktop：未运行"
fi

# ---------------------------------------------------------------------------
ddz_step "[6/6] 备份清单 ......"
if [ -d "$DDZ_BACKUP_ROOT" ]; then
  n=0
  for d in $(ls -1dt "$DDZ_BACKUP_ROOT"/*/ 2>/dev/null); do
    d="${d%/}"
    [ -f "$d/app-asar-backup.bin" ] || continue
    n=$((n + 1))
    printf '  [%d] %s\n' "$n" "$(basename "$d")"
    printf '      Docker 版本：%s   状态：%s\n' "$(cat "$d/VERSION" 2>/dev/null || echo '?')" "$(cat "$d/STATE" 2>/dev/null || echo '?')"
    printf '      大小：%s 字节\n' "$(stat -f %z "$d/app-asar-backup.bin" 2>/dev/null || echo 0)"
    printf '      SHA256：%s\n' "$(ddz_sha256_file "$d/app-asar-backup.bin")"
    if [ -f "$d/SHA256SUMS.txt" ]; then
      if ( cd "$d" && shasum -a 256 -c SHA256SUMS.txt >/dev/null 2>&1 ); then
        printf '      自检：%s通过%s\n' "$DDZ_C_GRN" "$DDZ_C_RST"
      else
        printf '      自检：%s未通过%s\n' "$DDZ_C_RED" "$DDZ_C_RST"
      fi
    fi
  done
  if [ "$n" -eq 0 ]; then
    ddz_warn "备份目录为空：$DDZ_BACKUP_ROOT"
  fi
else
  ddz_warn "尚无备份目录（未执行过汉化）：$DDZ_BACKUP_ROOT"
fi

printf '\n'
ddz_rule
printf '  诊断完成\n'
ddz_rule
printf '\n'
ddz_info "  · 上游项目：$DDZ_DDCS_HOME"
ddz_info "  · 翻译表版本不匹配时，见上游 releases 中对应版本的成品包"
ddz_pause
