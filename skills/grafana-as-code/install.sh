#!/usr/bin/env bash
# install.sh —— grafana-as-code skill 安装/更新脚本（仅 Claude Code）
#
# 作用：把本 skill 安装到 ~/.claude/skills/grafana-as-code/，并做依赖/凭证体检：
#   - skill 本体：     ~/.claude/skills/grafana-as-code/
#   - 运行依赖：       python3 + pyyaml（deploy/grafana 的 generate/push 脚本要用）
#   - 凭证源：         ~/github/my_dot_files/secrets.sh 须导出 GRAFANA_URL / GRAFANA_TOKEN
#
# 注：本脚本只管 Claude Code。仓库根目录的 sync.sh 会把所有 skill 同步到
#     ~/.claude/skills 和 ~/.agents/skills（OpenClaw）两处。
#
# 使用：
#   ./install.sh                # 安装 / 更新（含依赖与凭证体检）
#   ./install.sh --dry-run      # 预览，不实际改文件
#   ./install.sh --force        # 覆盖本地已有的同名 skill（⚠️ 谨慎）
#   ./install.sh --uninstall    # 卸载本 skill
#   ./install.sh --help
#
# 设计原则：
#   - 默认不覆盖本地已有、非本脚本安装的同名 skill（安全，用 marker 识别）
#   - skill 本体安装是硬需求；依赖/凭证缺失只告警，不阻断安装
#   - 所有操作可 dry-run，有 uninstall 逆操作

set -euo pipefail
IFS=$'\n\t'

# ============== 配置 ==============
SKILL_NAME="grafana-as-code"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_SKILLS="${HOME}/.claude/skills"

# skill 目录里的标记文件，用于识别"本脚本安装的 skill"
INSTALL_MARKER=".installed-by-grafana-as-code"

# 运行依赖与凭证源
SECRETS_FILE="${HOME}/github/my_dot_files/secrets.sh"

# ============== 颜色输出 ==============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[info]${NC} $*"; }
success() { echo -e "${GREEN}[ok]${NC} $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC} $*"; }
error()   { echo -e "${RED}[error]${NC} $*" >&2; }

# ============== 参数解析 ==============
DRY_RUN=0
FORCE=0
UNINSTALL=0

usage() {
  cat <<EOF
用法：
  $0                安装 / 更新本 skill（含依赖与凭证体检，仅 Claude Code）
  $0 --dry-run      预览将要执行的操作，不实际改文件
  $0 --force        遇到本地已有同名 skill 时强制覆盖（⚠️ 谨慎）
  $0 --uninstall    卸载本 skill
  $0 --help         打印本帮助

目标路径：
  SOURCE_DIR     = $SOURCE_DIR
  TARGET_SKILLS  = $TARGET_SKILLS/$SKILL_NAME
  SECRETS_FILE   = $SECRETS_FILE （须导出 GRAFANA_URL / GRAFANA_TOKEN）
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=1; shift ;;
    --force)     FORCE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)
      error "未知参数: $1"
      usage
      exit 1
      ;;
  esac
done

# ============== 前置校验（硬需求：仅 SKILL.md 源文件）==============
preflight() {
  info "前置校验..."

  if [[ ! -f "$SOURCE_DIR/SKILL.md" ]]; then
    error "源目录缺少 SKILL.md: $SOURCE_DIR/SKILL.md"
    error "请在 grafana-as-code skill 目录下运行本脚本"
    exit 2
  fi

  if [[ ! -d "$TARGET_SKILLS" ]]; then
    warn "目标目录不存在: $TARGET_SKILLS"
    if [[ $DRY_RUN -eq 0 ]]; then
      mkdir -p "$TARGET_SKILLS"
      success "已创建 $TARGET_SKILLS"
    else
      info "(dry-run) 会创建 $TARGET_SKILLS"
    fi
  fi

  success "前置校验通过"
}

# ============== 依赖体检（软需求：缺失只告警）==============
check_runtime_deps() {
  info "依赖体检（缺失不阻断安装，但会影响实际推送）..."

  # 1. python3
  if ! command -v python3 &>/dev/null; then
    warn "未找到 python3 —— deploy/grafana 的 generate/push 脚本无法运行"
    warn "  安装：brew install python3"
  else
    success "python3: $(python3 --version 2>&1)"
  fi

  # 2. pyyaml（generate.py / push.py 需要 import yaml）
  if command -v python3 &>/dev/null; then
    if python3 -c "import yaml" 2>/dev/null; then
      success "pyyaml: 已安装"
    else
      warn "缺少 pyyaml（deploy/grafana 脚本需 import yaml）"
      if [[ $DRY_RUN -eq 0 ]]; then
        info "尝试安装：python3 -m pip install 'pyyaml>=6.0'"
        if python3 -m pip install 'pyyaml>=6.0' 2>/dev/null; then
          success "pyyaml 安装成功"
        else
          warn "自动安装失败，请手动执行：python3 -m pip install 'pyyaml>=6.0'"
        fi
      else
        info "(dry-run) 会尝试：python3 -m pip install 'pyyaml>=6.0'"
      fi
    fi
  fi
}

# ============== 凭证体检（软需求：缺失只告警）==============
check_credentials() {
  info "凭证体检..."
  if [[ -f "$SECRETS_FILE" ]] \
     && grep -q 'GRAFANA_URL' "$SECRETS_FILE" \
     && grep -q 'GRAFANA_TOKEN' "$SECRETS_FILE"; then
    success "凭证源 OK：$SECRETS_FILE 已定义 GRAFANA_URL / GRAFANA_TOKEN"
  else
    warn "未在 $SECRETS_FILE 找到 GRAFANA_URL / GRAFANA_TOKEN"
    warn "  参考 $SOURCE_DIR/secrets.example.sh，把两行 export 加进你的 secrets.sh"
    warn "  （token 绝不入库；skill 运行时会 source 该文件注入 env）"
  fi
}

# ============== 冲突检测 ==============
detect_conflicts() {
  info "检查命名冲突..."
  local dst="$TARGET_SKILLS/$SKILL_NAME"
  if [[ -e "$dst" ]] && [[ ! -f "$dst/$INSTALL_MARKER" ]]; then
    warn "检测到本地已有 skill（非本脚本安装）：$dst"
    if [[ $FORCE -eq 1 ]]; then
      warn "已指定 --force，将覆盖它（⚠️ 会覆盖本地已有的同名 skill！）"
    else
      error "遇到冲突，停止安装。"
      error "确认要覆盖请重跑加 --force：  $0 --force"
      exit 5
    fi
  else
    success "无冲突，可以安装"
  fi
}

# ============== 安装 ==============
do_install() {
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info " grafana-as-code · 安装脚本"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  [[ $DRY_RUN -eq 1 ]] && warn "dry-run 模式：不会实际修改文件"

  preflight
  detect_conflicts

  # 安装 skill 本体（原子更新：先拷临时目录再替换）
  local dst="$TARGET_SKILLS/$SKILL_NAME"
  local tmp="${dst}.tmp.$$"
  if [[ -e "$dst" ]]; then
    info "[更新] skill → $dst"
  else
    info "[新增] skill → $dst"
  fi
  if [[ $DRY_RUN -eq 0 ]]; then
    rm -rf "$tmp"
    cp -R "$SOURCE_DIR" "$tmp"
    # 安装到 ~/.claude 的副本不需要保留安装脚本自身与 VCS 痕迹
    rm -f "$tmp/install.sh"
    rm -rf "$tmp/.git"
    touch "$tmp/$INSTALL_MARKER"
    rm -rf "$dst"
    mv "$tmp" "$dst"
  fi

  check_runtime_deps
  check_credentials

  echo ""
  if [[ $DRY_RUN -eq 0 ]]; then
    success "✅ 安装完成：grafana-as-code"
  else
    info "(dry-run) 将安装：grafana-as-code"
  fi
  echo ""
  info "后续步骤："
  info "  1. 确保 deploy/grafana/ 已提交进 tipsy-backend 仓库（skill 靠 git 根定位它）"
  info "  2. 确保 $SECRETS_FILE 导出 GRAFANA_URL / GRAFANA_TOKEN"
  info "  3. 重启 Claude Code 会话或开新对话，skill 列表应出现 grafana-as-code"
}

# ============== 卸载 ==============
do_uninstall() {
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info " grafana-as-code · 卸载脚本"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  [[ $DRY_RUN -eq 1 ]] && warn "dry-run 模式：不会实际删除"

  local dst="$TARGET_SKILLS/$SKILL_NAME"
  if [[ -e "$dst" ]]; then
    if [[ -f "$dst/$INSTALL_MARKER" ]] || [[ $FORCE -eq 1 ]]; then
      info "[删除] skill $dst"
      [[ $DRY_RUN -eq 0 ]] && rm -rf "$dst"
    else
      warn "[跳过] ${dst}（无安装标记，可能是本地自有 skill；--force 可强删）"
    fi
  else
    info "未安装，无需卸载：$dst"
  fi

  echo ""
  if [[ $DRY_RUN -eq 0 ]]; then
    success "卸载完成"
  else
    info "(dry-run) 卸载预览结束"
  fi
}

# ============== 主入口 ==============
if [[ $UNINSTALL -eq 1 ]]; then
  do_uninstall
else
  do_install
fi
