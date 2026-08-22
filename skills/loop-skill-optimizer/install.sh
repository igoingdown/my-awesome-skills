#!/usr/bin/env bash
# 安装/自检 loop-skill-optimizer。
#   ./install.sh --help        用法
#   ./install.sh doctor        自检依赖与配置
#   ./install.sh init-config   生成本地配置模板
#   ./install.sh install-cron  装 crontab 条目（每 30 分钟 + @reboot 补跑）
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SKILL_DIR/scripts/optimizer.sh"
CONFIG="${LOOP_SKILL_OPTIMIZER_CONFIG:-$HOME/.config/loop-skill-optimizer.sh}"

usage() {
  sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

doctor() {
  local ok=1
  for c in git gh claude python3; do
    if command -v "$c" >/dev/null 2>&1; then echo "  ✓ $c"; else echo "  ✗ 缺少 $c"; ok=0; fi
  done
  if gh auth status >/dev/null 2>&1; then echo "  ✓ gh 已登录"; else echo "  ✗ gh 未登录（gh auth login）"; ok=0; fi
  if [ -f "$CONFIG" ]; then
    echo "  ✓ 配置存在: $CONFIG"
    # shellcheck source=/dev/null
    source "$CONFIG"
    [ -n "${SKILL_REPO_SLUG:-}" ] && echo "    ✓ SKILL_REPO_SLUG=$SKILL_REPO_SLUG" || { echo "    ✗ SKILL_REPO_SLUG 未设"; ok=0; }
    [ -d "${SKILL_REPO_DIR:-/nonexistent}" ] && echo "    ✓ SKILL_REPO_DIR 存在" || { echo "    ✗ SKILL_REPO_DIR 不存在"; ok=0; }
    [ -n "${NOTIFY_CMD:-}" ] && command -v "${NOTIFY_CMD%% *}" >/dev/null 2>&1 \
      && echo "    ✓ NOTIFY_CMD 可用" || echo "    ⚠ NOTIFY_CMD 未设或不可用（不发通知，仅写日志）"
  else
    echo "  ✗ 未找到配置: $CONFIG（先跑 ./install.sh init-config）"; ok=0
  fi
  [ "$ok" = 1 ] && echo "自检通过。" || { echo "自检未通过，按上面修复。"; return 1; }
}

init_config() {
  mkdir -p "$(dirname "$CONFIG")"
  if [ -f "$CONFIG" ]; then echo "配置已存在: $CONFIG（不覆盖）"; return; fi
  cp "$SKILL_DIR/config.example.sh" "$CONFIG"
  echo "已生成 $CONFIG，请编辑填入真实值（这些值不要提交进公开仓库）。"
}

install_cron() {
  local line1="*/30 * * * * $SCRIPT --cron >/dev/null 2>&1"
  local line2="@reboot sleep 120; $SCRIPT --cron >/dev/null 2>&1"
  ( crontab -l 2>/dev/null | grep -vF "$SCRIPT"; echo "$line1"; echo "$line2" ) | crontab -
  echo "已安装 crontab 条目："
  echo "  $line1"
  echo "  $line2"
}

case "${1:-doctor}" in
  --help|-h|help) usage ;;
  doctor) doctor ;;
  init-config) init_config ;;
  install-cron) install_cron ;;
  *) usage; exit 1 ;;
esac
