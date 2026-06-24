#!/usr/bin/env bash
# install.sh —— long-task-manager skill 安装/更新脚本（仅 Claude Code）
#
# 作用：把本 skill 安装到 Claude Code 的两个位置：
#   - skill 本体：     ~/.claude/skills/long-task-manager/
#   - 4 个 subagent：  ~/.claude/agents/long-task-*.md
#
# subagent 必须装到 ~/.claude/agents/ 才会被 Claude Code 识别，
# 仅把 skill 拷到 ~/.claude/skills/ 是不够的——委派会失效。
#
# 使用：
#   ./install.sh                # 安装 / 更新
#   ./install.sh --dry-run      # 预览，不实际改文件
#   ./install.sh --force        # 覆盖本地已有的同名 skill / agent（⚠️ 谨慎）
#   ./install.sh --uninstall    # 卸载本 skill 及其 subagent
#   ./install.sh --help
#
# 设计原则：
#   - 默认不覆盖本地已有、非本脚本安装的同名 skill / agent（安全）
#   - 用 manifest 标记文件可靠识别"本脚本安装的内容"
#   - 所有操作可 dry-run，有 uninstall 逆操作

set -euo pipefail
IFS=$'\n\t'

# ============== 配置 ==============
SKILL_NAME="long-task-manager"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_SKILLS="${HOME}/.claude/skills"
TARGET_AGENTS="${HOME}/.claude/agents"

# skill 目录里的标记文件，用于识别"本脚本安装的 skill"
INSTALL_MARKER=".installed-by-long-task-manager"

# subagent 文件名（与 claude-agents/ 下文件名、frontmatter name 一致）
AGENT_FILES=(
  "long-task-implementer.md"
  "long-task-researcher.md"
  "long-task-reviewer.md"
  "long-task-verifier.md"
)

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
  $0                安装 / 更新本 skill 及其 4 个 subagent（仅 Claude Code）
  $0 --dry-run      预览将要执行的操作，不实际改文件
  $0 --force        遇到本地已有同名 skill / agent 时强制覆盖（⚠️ 谨慎）
  $0 --uninstall    卸载本 skill 及其 subagent
  $0 --help         打印本帮助

目标路径：
  SOURCE_DIR     = $SOURCE_DIR
  TARGET_SKILLS  = $TARGET_SKILLS/$SKILL_NAME
  TARGET_AGENTS  = $TARGET_AGENTS/{${AGENT_FILES[*]}}
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

# ============== 前置校验 ==============
preflight() {
  info "前置校验..."

  # 1. 源 SKILL.md 存在
  if [[ ! -f "$SOURCE_DIR/SKILL.md" ]]; then
    error "源目录缺少 SKILL.md: $SOURCE_DIR/SKILL.md"
    error "请在 long-task-manager skill 目录下运行本脚本"
    exit 2
  fi

  # 2. 4 个 agent 源文件都在
  local missing=()
  local af
  for af in "${AGENT_FILES[@]}"; do
    if [[ ! -f "$SOURCE_DIR/claude-agents/$af" ]]; then
      missing+=("$af")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    error "以下 subagent 源文件缺失（应在 $SOURCE_DIR/claude-agents/ 下）："
    local m
    for m in "${missing[@]}"; do
      error "  - $m"
    done
    exit 3
  fi

  # 3. 目标目录存在或可创建
  local target
  for target in "$TARGET_SKILLS" "$TARGET_AGENTS"; do
    if [[ ! -d "$target" ]]; then
      warn "目标目录不存在: $target"
      if [[ $DRY_RUN -eq 0 ]]; then
        mkdir -p "$target"
        success "已创建 $target"
      else
        info "(dry-run) 会创建 $target"
      fi
    fi
  done

  success "前置校验通过"
}

# ============== 冲突检测 ==============
# 本脚本安装的 skill 带 INSTALL_MARKER；agent 文件名带 long-task- 前缀，
# 且 uninstall 只删与源内容一致的文件，避免误伤用户自有内容。
detect_conflicts() {
  info "检查命名冲突..."
  local conflict=0

  # skill 冲突：目标存在但无安装标记 = 用户自有
  local dst="$TARGET_SKILLS/$SKILL_NAME"
  if [[ -e "$dst" ]] && [[ ! -f "$dst/$INSTALL_MARKER" ]]; then
    warn "检测到本地已有 skill（非本脚本安装）：$dst"
    conflict=1
  fi

  # agent 冲突：目标文件存在但内容与源不同 = 用户改过或自有
  local af
  for af in "${AGENT_FILES[@]}"; do
    local adst="$TARGET_AGENTS/$af"
    if [[ -e "$adst" ]] && ! cmp -s "$SOURCE_DIR/claude-agents/$af" "$adst"; then
      warn "检测到本地已有 agent 且内容不同：$adst"
      conflict=1
    fi
  done

  if [[ $conflict -eq 1 ]]; then
    if [[ $FORCE -eq 1 ]]; then
      warn "已指定 --force，将覆盖上述内容"
      warn "⚠️ 这会覆盖本地已有的同名 skill / agent！"
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
  info " long-task-manager · 安装脚本"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  [[ $DRY_RUN -eq 1 ]] && warn "dry-run 模式：不会实际修改文件"

  preflight
  detect_conflicts

  # 1. 安装 skill 本体（原子更新：先拷临时目录再替换）
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
    # 临时目录里不需要保留安装脚本自身和 VCS 痕迹
    rm -f "$tmp/install.sh"
    touch "$tmp/$INSTALL_MARKER"
    rm -rf "$dst"
    mv "$tmp" "$dst"
    [[ -d "$dst/scripts" ]] && find "$dst/scripts" -name "*.sh" -exec chmod +x {} \;
  fi

  # 2. 安装 4 个 subagent 到 ~/.claude/agents/
  local af
  for af in "${AGENT_FILES[@]}"; do
    info "[agent] $af → $TARGET_AGENTS/$af"
    if [[ $DRY_RUN -eq 0 ]]; then
      cp "$SOURCE_DIR/claude-agents/$af" "$TARGET_AGENTS/$af"
    fi
  done

  echo ""
  if [[ $DRY_RUN -eq 0 ]]; then
    success "✅ 安装完成：skill + ${#AGENT_FILES[@]} 个 subagent"
  else
    info "(dry-run) 将安装：skill + ${#AGENT_FILES[@]} 个 subagent"
  fi
  echo ""
  info "后续步骤：重启 Claude Code 会话或开新对话，"
  info "skill 列表应出现 long-task-manager，subagent 列表应出现 long-task-*。"
}

# ============== 卸载 ==============
do_uninstall() {
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info " long-task-manager · 卸载脚本"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  [[ $DRY_RUN -eq 1 ]] && warn "dry-run 模式：不会实际删除"

  # 1. 卸载 skill（仅删本脚本安装的，凭 manifest 标记）
  local dst="$TARGET_SKILLS/$SKILL_NAME"
  if [[ -e "$dst" ]]; then
    if [[ -f "$dst/$INSTALL_MARKER" ]] || [[ $FORCE -eq 1 ]]; then
      info "[删除] skill $dst"
      [[ $DRY_RUN -eq 0 ]] && rm -rf "$dst"
    else
      warn "[跳过] ${dst}（无安装标记，可能是本地自有 skill；--force 可强删）"
    fi
  fi

  # 2. 卸载 agent（仅删与源内容一致的，避免误删用户改过的版本）
  local af
  for af in "${AGENT_FILES[@]}"; do
    local adst="$TARGET_AGENTS/$af"
    if [[ -e "$adst" ]]; then
      if cmp -s "$SOURCE_DIR/claude-agents/$af" "$adst" || [[ $FORCE -eq 1 ]]; then
        info "[删除] agent $adst"
        [[ $DRY_RUN -eq 0 ]] && rm -f "$adst"
      else
        warn "[跳过] ${adst}（内容与源不同，可能被本地修改过；--force 可强删）"
      fi
    fi
  done

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
