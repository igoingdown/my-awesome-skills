#!/usr/bin/env bash
# 安装/自检 loop-daily-retro。
#   ./install.sh --help        用法
#   ./install.sh doctor        自检依赖与配置
#   ./install.sh init-config   生成本地配置模板
#   ./install.sh install-cron  装 crontab 条目（每天上午）
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SKILL_DIR/scripts/daily-retro.sh"
CONFIG="${LOOP_DAILY_RETRO_CONFIG:-$HOME/.config/loop-daily-retro.sh}"

usage() { sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

doctor() {
  local ok=1
  for c in claude python3; do
    if command -v "$c" >/dev/null 2>&1; then echo "  ✓ $c"; else echo "  ✗ 缺少 $c"; ok=0; fi
  done
  if [ -f "$CONFIG" ]; then
    echo "  ✓ 配置存在: $CONFIG"
    # shellcheck source=/dev/null
    source "$CONFIG"
    [ -n "${REPORT_OWNER:-}" ] && echo "    ✓ REPORT_OWNER=$REPORT_OWNER" || { echo "    ✗ REPORT_OWNER 未设"; ok=0; }
    command -v "${DOC_CLI%% *}" >/dev/null 2>&1 && echo "    ✓ DOC_CLI 可用" || echo "    ⚠ DOC_CLI 未安装（需你自备云文档 CLI）"
    [ -n "${NOTIFY_CMD:-}" ] && command -v "${NOTIFY_CMD%% *}" >/dev/null 2>&1 \
      && echo "    ✓ NOTIFY_CMD 可用" || echo "    ⚠ NOTIFY_CMD 未设或不可用（不发通知，仅写日志）"
    [ -n "${IM_DIGEST_CMD:-}" ] && echo "    ✓ IM_DIGEST_CMD 已设（复盘会带 IM 素材）" || echo "    ⚠ IM_DIGEST_CMD 未设（复盘只基于 session）"
  else
    echo "  ✗ 未找到配置: $CONFIG（先跑 ./install.sh init-config）"; ok=0
  fi
  [ "$ok" = 1 ] && echo "自检通过。" || { echo "自检未通过，按上面修复。"; return 1; }
}

init_config() {
  mkdir -p "$(dirname "$CONFIG")"
  if [ -f "$CONFIG" ]; then echo "配置已存在: $CONFIG（不覆盖）"; return; fi
  cp "$SKILL_DIR/config.example.sh" "$CONFIG"
  echo "已生成 $CONFIG，请编辑填入真实值（不要提交进公开仓库）。"
}

install_cron() {
  # 上午 10:07——错开整点，避开与其它定时任务撞车（见 SKILL.md 错峰一节）
  local line="7 10 * * * $SCRIPT >/dev/null 2>&1"
  ( crontab -l 2>/dev/null | grep -vF "$SCRIPT"; echo "$line" ) | crontab -
  echo "已安装 crontab 条目（每天 10:07）："
  echo "  $line"
}

case "${1:-doctor}" in
  --help|-h|help) usage ;;
  doctor) doctor ;;
  init-config) init_config ;;
  install-cron) install_cron ;;
  *) usage; exit 1 ;;
esac
