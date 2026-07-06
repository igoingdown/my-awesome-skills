#!/usr/bin/env bash
# install.sh —— logfire-ops skill 安装/更新脚本（仅 Claude Code）
#
# 作用：把本 skill 安装到 ~/.claude/skills/logfire-ops/，并配置/体检它依赖的
#       Pydantic Logfire MCP server：
#   - skill 本体：   ~/.claude/skills/logfire-ops/
#   - 运行依赖：     claude CLI（用于配置 MCP server）
#   - MCP server：   logfire（HTTP transport + Logfire read token，user scope）
#
# 注：本脚本只管 Claude Code。仓库根目录的 sync.sh 会把所有 skill 同步到
#     ~/.claude/skills 和 ~/.agents/skills（OpenClaw）两处——但 sync.sh 不配 MCP，
#     首次使用本 skill 仍需跑一次本脚本（或手动 claude mcp add）来接上 logfire MCP。
#
# 使用：
#   ./install.sh                         # 安装 / 更新（含 MCP 配置与体检）
#   ./install.sh --dry-run               # 预览，不实际改文件
#   ./install.sh --force                 # 覆盖本地已有的同名 skill（⚠️ 谨慎）
#   ./install.sh --uninstall             # 卸载本 skill
#   ./install.sh --skill-only            # 只装 skill，不碰 MCP
#   ./install.sh --mcp-only              # 只配 MCP，不复制 skill
#   ./install.sh --force-mcp             # 即使已配置也重配 logfire MCP
#   ./install.sh --token pylf_...        # 直接传 read token（也可用环境变量）
#   LOGFIRE_READ_TOKEN=pylf_... ./install.sh
#   ./install.sh --region eu             # EU 区（默认 us）
#   ./install.sh --url <mcp-url>         # 自定义 MCP URL（覆盖 --region）
#   ./install.sh --help
#
# read token 怎么拿：Logfire → 选 tipsy 项目 → Settings → Read tokens → Create。
#   token 形如 pylf_v2_us_...，是只读密钥。本脚本不内置任何 token，
#   也不会回显你输入的 token，更不会把它写进仓库。
#
# 设计原则：
#   - 默认不覆盖本地已有、非本脚本安装的同名 skill（用 marker 识别）
#   - skill 本体安装是硬需求；MCP/依赖缺失只告警，不阻断安装
#   - 所有操作可 dry-run，有 uninstall 逆操作

set -euo pipefail
IFS=$'\n\t'

# ============== 配置 ==============
SKILL_NAME="logfire-ops"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_SKILLS="${HOME}/.claude/skills"

# skill 目录里的标记文件，用于识别"本脚本安装的 skill"
INSTALL_MARKER=".installed-by-logfire-ops"

# MCP 配置
REGION="us"
MCP_URL=""
TOKEN="${LOGFIRE_READ_TOKEN:-}"

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
DO_SKILL=1
DO_MCP=1
FORCE_MCP=0

usage() {
  cat <<EOF
用法：
  $0                安装 / 更新本 skill（含 MCP 配置与体检，仅 Claude Code）
  $0 --dry-run      预览将要执行的操作，不实际改文件
  $0 --force        遇到本地已有同名 skill 时强制覆盖（⚠️ 谨慎）
  $0 --uninstall    卸载本 skill
  $0 --skill-only   只装 skill，不配置 logfire MCP
  $0 --mcp-only     只配置 logfire MCP，不复制 skill
  $0 --force-mcp    即使已配置也重配 logfire MCP
  $0 --token <tok>  直接传 Logfire read token（亦可用 LOGFIRE_READ_TOKEN 环境变量）
  $0 --region <r>   Logfire 区域 us（默认）/ eu
  $0 --url <url>    自定义 MCP URL（覆盖 --region 推导）
  $0 --help         打印本帮助

目标路径：
  SOURCE_DIR     = $SOURCE_DIR
  TARGET_SKILLS  = $TARGET_SKILLS/$SKILL_NAME

read token：Logfire → tipsy 项目 → Settings → Read tokens → Create
  token 是只读密钥，本脚本不内置、不回显、不入库。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=1; shift ;;
    --force)      FORCE=1; shift ;;
    --uninstall)  UNINSTALL=1; shift ;;
    --skill-only) DO_MCP=0; shift ;;
    --mcp-only)   DO_SKILL=0; shift ;;
    --force-mcp)  FORCE_MCP=1; shift ;;
    --token)      TOKEN="${2:-}"; shift 2 ;;
    --token=*)    TOKEN="${1#*=}"; shift ;;
    --region)     REGION="${2:-us}"; shift 2 ;;
    --region=*)   REGION="${1#*=}"; shift ;;
    --url)        MCP_URL="${2:-}"; shift 2 ;;
    --url=*)      MCP_URL="${1#*=}"; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)
      error "未知参数: $1"
      usage
      exit 1
      ;;
  esac
done

[[ -z "$MCP_URL" ]] && MCP_URL="https://logfire-${REGION}.pydantic.dev/mcp"

# ============== 前置校验（硬需求：仅 SKILL.md 源文件）==============
preflight() {
  info "前置校验..."

  if [[ ! -f "$SOURCE_DIR/SKILL.md" ]]; then
    error "源目录缺少 SKILL.md: $SOURCE_DIR/SKILL.md"
    error "请在 logfire-ops skill 目录下运行本脚本"
    exit 2
  fi

  if [[ $DO_SKILL -eq 1 && ! -d "$TARGET_SKILLS" ]]; then
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

# ============== 安装 skill 本体 ==============
install_skill() {
  if [[ $DO_SKILL -eq 0 ]]; then
    warn "跳过 skill 复制（--mcp-only）"
    return
  fi

  detect_conflicts

  # 原子更新：先拷临时目录再替换
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
    success "skill 已安装到 $dst"
  else
    info "(dry-run) 会安装 skill 到 $dst"
  fi
}

# ============== 配置 logfire MCP（软需求：缺失只告警）==============
configure_mcp() {
  if [[ $DO_MCP -eq 0 ]]; then
    warn "跳过 MCP 配置（--skill-only）"
    return
  fi

  info "配置 logfire MCP（HTTP transport，user scope）..."
  info "  MCP URL: $MCP_URL"

  if ! command -v claude &>/dev/null; then
    warn "未找到 claude CLI，跳过 MCP 自动配置"
    warn "  请手动执行（替换 <TOKEN>）："
    warn "  claude mcp add --transport http logfire \"$MCP_URL\" --header \"Authorization: Bearer <TOKEN>\" -s user"
    return
  fi

  local already=0
  if claude mcp get logfire &>/dev/null; then already=1; fi

  if [[ $already -eq 1 && $FORCE_MCP -eq 0 ]]; then
    info "已有 logfire MCP 配置，体检连接..."
    if claude mcp list 2>/dev/null | grep -q "logfire:.*Connected"; then
      success "logfire MCP 已配置且连接正常，保持原样（要重配加 --force-mcp）"
    else
      warn "logfire MCP 已有配置，但连接体检未通过"
      warn "  常见原因：之前 claude mcp add 时没带 token（显示 Needs authentication），或 token 失效"
      warn "  带 token 重配：LOGFIRE_READ_TOKEN=pylf_... $0 --mcp-only --force-mcp"
    fi
    return
  fi

  if [[ -z "$TOKEN" ]]; then
    if [[ -t 0 && $DRY_RUN -eq 0 ]]; then
      echo -e "${BLUE}需要 Logfire read token（Logfire → tipsy 项目 → Settings → Read tokens → Create）${NC}"
      echo -e "${BLUE}忘了之前的 token 存哪？网页上不会再显示完整值，但配过的机器上常有副本，可以扫一下：${NC}"
      echo -e "${BLUE}  grep -rho 'pylf_[a-zA-Z0-9_]*' ~/.claude.json ~/.cursor/mcp.json ~/.codex/config.toml 2>/dev/null | sort -u${NC}"
      printf "粘贴 read token（输入不回显）: "
      read -rs TOKEN
      echo
    fi
  fi

  if [[ -z "$TOKEN" ]]; then
    warn "没有提供 token，跳过 MCP 配置（skill 本体不受影响）"
    warn "  配好 token 后重跑：LOGFIRE_READ_TOKEN=pylf_... $0 --mcp-only"
    warn "  或走官方 OAuth（有浏览器时）："
    warn "    claude mcp add --transport http logfire \"$MCP_URL\" -s user"
    warn "    然后在 Claude Code 里执行 /mcp → logfire → 完成浏览器登录"
    return
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) 会重配 logfire MCP：claude mcp add --transport http logfire \"$MCP_URL\" --header \"Authorization: Bearer ***\" -s user"
    return
  fi

  claude mcp remove logfire -s user &>/dev/null || true
  claude mcp remove logfire &>/dev/null || true
  claude mcp add --transport http logfire "$MCP_URL" \
    --header "Authorization: Bearer $TOKEN" -s user

  info "体检 MCP 连接..."
  if claude mcp list 2>/dev/null | grep -q "logfire:.*Connected"; then
    success "logfire MCP 已配置并连接成功（user scope）"
  else
    warn "logfire MCP 已写入配置，但连接体检未通过——token 可能无效或已过期"
    warn "  手动检查：claude mcp list；换 token 重跑：$0 --mcp-only --force-mcp"
  fi
}

# ============== 安装主流程 ==============
do_install() {
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info " logfire-ops · 安装脚本"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  [[ $DRY_RUN -eq 1 ]] && warn "dry-run 模式：不会实际修改文件"

  preflight
  install_skill
  configure_mcp

  echo ""
  if [[ $DRY_RUN -eq 0 ]]; then
    success "✅ 安装完成：logfire-ops"
  else
    info "(dry-run) 将安装：logfire-ops"
  fi
  echo ""
  info "后续步骤："
  info "  1. 验证 MCP：claude mcp list  应看到 logfire ... ✓ Connected"
  info "  2. 重启 Claude Code 会话或开新对话，skill 列表应出现 logfire-ops"
  info "     （MCP 工具在会话启动时加载，已打开的会话不会自动生效）"
  info "  3. 触发示例：「读一下线上告警」/「在 ddd 看板加个 5xx panel」/"
  info "             「这个报错帮我看下根因（trace_id ...）」"
}

# ============== 卸载 ==============
do_uninstall() {
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info " logfire-ops · 卸载脚本"
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

  warn "未自动移除 logfire MCP（可能被其它 skill 共用）。"
  warn "  如需移除：claude mcp remove logfire -s user"

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
