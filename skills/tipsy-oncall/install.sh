#!/usr/bin/env bash
# install.sh —— tipsy-oncall skill 安装/更新脚本(仅 Claude Code)
#
# 作用:
#   1. 把 skill 装到 ~/.claude/skills/tipsy-oncall/(原子替换)
#   2. 检测 4 个必需 MCP(bytebase/signoz/logfire/aliyun-sls),缺则打印补装命令
#   3. 检测 coolify CLI + jq + python3(软需求)
#   4. 把 tipsy-oncall 需要的 secrets 键追加到 ~/github/my_dot_files/secrets.sh
#      —— 值留空,已存在的键跳过,marker 块识别整段,幂等
#   5. --replace-legacy 显式清理旧的项目级 tipsy-debug skill
#
# 注:仓库根目录的 sync.sh 会把所有 skill 同步到 ~/.claude/skills 和 ~/.agents/skills
#     两处 —— 但 sync.sh 不追加 secrets、不体检 MCP,首次装仍需跑本脚本。

set -euo pipefail
IFS=$'\n\t'

# ============== 配置 ==============
SKILL_NAME="tipsy-oncall"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_SKILLS="${HOME}/.claude/skills"

# skill 目录里的标记文件(用于识别"本脚本安装的 skill")
INSTALL_MARKER=".installed-by-tipsy-oncall"

# 凭证源
SECRETS_FILE="${HOME}/github/my_dot_files/secrets.sh"
SECRETS_MARKER_BEGIN="# tipsy-oncall skill (auto-append by install.sh)"
SECRETS_MARKER_END="# end of tipsy-oncall skill"

# 旧的项目级 tipsy-debug skill(--replace-legacy 才删)
LEGACY_SKILL_DIR="${HOME}/github/tipsy-backend/.claude/skills/tipsy-debug"

# 必需 MCP
REQUIRED_MCPS=(bytebase signoz logfire aliyun-sls)

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
REPLACE_LEGACY=0

usage() {
  cat <<EOF
用法:
  $0                      安装 / 更新本 skill(含 secrets append 与 MCP 体检)
  $0 --dry-run            预览将要执行的操作,不实际改文件
  $0 --force              遇到本地已有同名 skill 时强制覆盖(⚠️ 谨慎)
  $0 --uninstall          卸载本 skill(不动 secrets.sh、不移除 MCP)
  $0 --replace-legacy     显式清理旧的项目级 tipsy-debug skill(只删项目主目录那份)
  $0 --help               打印本帮助

目标路径:
  SOURCE_DIR       = $SOURCE_DIR
  TARGET_SKILLS    = $TARGET_SKILLS/$SKILL_NAME
  SECRETS_FILE     = $SECRETS_FILE
  LEGACY_SKILL_DIR = $LEGACY_SKILL_DIR (需 --replace-legacy 才动)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)         DRY_RUN=1; shift ;;
    --force)           FORCE=1; shift ;;
    --uninstall)       UNINSTALL=1; shift ;;
    --replace-legacy)  REPLACE_LEGACY=1; shift ;;
    -h|--help)         usage; exit 0 ;;
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

  if [[ ! -f "$SOURCE_DIR/SKILL.md" ]]; then
    error "源目录缺少 SKILL.md: $SOURCE_DIR/SKILL.md"
    error "请在 tipsy-oncall skill 目录下运行本脚本"
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

# ============== 冲突检测 ==============
detect_conflicts() {
  info "检查命名冲突..."
  local dst="$TARGET_SKILLS/$SKILL_NAME"
  if [[ -e "$dst" ]] && [[ ! -f "$dst/$INSTALL_MARKER" ]]; then
    # sync.sh 同步的副本与源目录内容一致 —— 可安全更新,不算冲突
    if diff -rq -x "$INSTALL_MARKER" -x "install.sh" "$SOURCE_DIR" "$dst" >/dev/null 2>&1; then
      success "已有副本与源目录内容一致(sync.sh 同步),直接更新"
      return
    fi
    warn "检测到本地已有 skill(非本脚本安装,且内容与源目录有差异):$dst"
    warn "  若它只是 sync.sh 同步的旧版本,--force 覆盖即可;若有手改请先备份"
    if [[ $FORCE -eq 1 ]]; then
      warn "已指定 --force,将覆盖它(⚠️ 会覆盖本地已有的同名 skill!)"
    else
      error "遇到冲突,停止安装。"
      error "确认要覆盖请重跑加 --force:  $0 --force"
      exit 5
    fi
  else
    success "无冲突,可以安装"
  fi
}

# ============== 安装 skill 本体 ==============
install_skill() {
  detect_conflicts

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

# ============== 依赖体检(软需求) ==============
check_runtime_deps() {
  info "依赖体检(缺失只 warn,不阻断)..."

  for cmd in jq python3 curl coolify; do
    if command -v "$cmd" &>/dev/null; then
      case "$cmd" in
        python3) success "$cmd: $(python3 --version 2>&1)" ;;
        coolify) success "$cmd: $(coolify --help 2>&1 | grep -m1 -oE 'Version: [0-9.]+' || echo 'installed')" ;;
        *)       success "$cmd: 已安装" ;;
      esac
    else
      warn "缺少 $cmd"
      case "$cmd" in
        jq)      warn "  安装:brew install jq" ;;
        python3) warn "  安装:brew install python3" ;;
        curl)    warn "  安装:通常系统自带" ;;
        coolify) warn "  安装:brew install coolify-cli(若不用 Coolify 副服务可忽略)" ;;
      esac
    fi
  done
}

# ============== MCP 体检 ==============
check_mcps() {
  info "MCP 体检(检测 ~/.claude.json 里是否已配 4 个必需 MCP)..."

  local claude_json="$HOME/.claude.json"
  if [[ ! -f "$claude_json" ]]; then
    warn "未找到 $claude_json,跳过 MCP 检测。首次跑 claude 会自动生成。"
    return
  fi

  if ! command -v jq &>/dev/null; then
    warn "缺 jq,跳过 MCP 检测(装 jq 后重跑可自动体检)"
    return
  fi

  local missing=()
  for name in "${REQUIRED_MCPS[@]}"; do
    if jq -e --arg n "$name" '.mcpServers[$n] // empty' "$claude_json" >/dev/null 2>&1; then
      success "MCP $name: 已配置"
    else
      warn "MCP $name: 未配置"
      missing+=("$name")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    warn ""
    warn "缺失的 MCP: ${missing[*]}"
    warn "补装参考(替换 <TOKEN> 为真实值):"
    for name in "${missing[@]}"; do
      case "$name" in
        bytebase)
          warn "  bytebase   → claude mcp add --transport http bytebase 'https://bytebase.infra.fantacy.live/mcp' -s user"
          ;;
        signoz)
          warn "  signoz     → 需先放 signoz-mcp-server 二进制到 ~/.local/bin,再:"
          warn "               claude mcp add signoz ~/.local/bin/signoz-mcp-server -s user \\"
          warn "                 -e SIGNOZ_URL='...' -e SIGNOZ_API_KEY='<TOKEN>' -e LOG_LEVEL=info"
          ;;
        logfire)
          warn "  logfire    → claude mcp add --transport http logfire 'https://logfire-us.pydantic.dev/mcp' \\"
          warn "                 --header 'Authorization:Bearer <TOKEN>' -s user"
          ;;
        aliyun-sls)
          warn "  aliyun-sls → 用 uvx:"
          warn "               claude mcp add aliyun-sls 'uvx --from mcp-server-aliyun-observability mcp-server-aliyun-observability --transport stdio' \\"
          warn "                 --args '--access-key-id' '\$ALIYUN_ACCESS_KEY_ID' '--access-key-secret' '\$ALIYUN_ACCESS_KEY_SECRET' -s user"
          ;;
      esac
    done
  fi
}

# ============== secrets append(核心 Q3=B) ==============
append_secrets() {
  info "secrets append(检测缺失键,追加到 $SECRETS_FILE)..."

  if [[ ! -f "$SECRETS_FILE" ]]; then
    warn "$SECRETS_FILE 不存在,跳过。"
    warn "  想要自动追加请先 mkdir -p $(dirname "$SECRETS_FILE") && touch $SECRETS_FILE 再重跑。"
    return
  fi

  # 定义需要的 keys(每个一行:KEY|COMMENT|DEFAULT_VALUE)
  local keys=(
    "ALIYUN_ACCESS_KEY_ID|Aliyun AK ID(建议单独 RAM 子账号 + kvstore:RunCommand)|"
    "ALIYUN_ACCESS_KEY_SECRET|Aliyun AK Secret|"
    "ALIYUN_REGION_ID|Redis/ES 所在 region|cn-hongkong"
    "ALIYUN_REDIS_INSTANCE_ID_PROD|Prod Redis 实例 ID(r-xxxxxxxxxxxx)|"
    "ALIYUN_REDIS_INSTANCE_ID_TEST|Test Redis 实例 ID|"
    "ALIYUN_ES_ENDPOINT_PROD|Prod ES endpoint(https://.../:9200,需开公网+白名单)|"
    "ALIYUN_ES_ENDPOINT_TEST|Test ES endpoint|"
    "ALIYUN_ES_USERNAME|ES 用户名|elastic"
    "ALIYUN_ES_PASSWORD|ES 密码|"
    "TIPSY_MEMORY_URL_PROD|Prod memory 服务 host|"
    "TIPSY_MEMORY_URL_TEST|Test memory 服务 host|"
    "ALIYUN_DMS_LINDORM_URL_PROD|Prod Lindorm DMS 页面 URL(Chrome 兜底)|"
    "ALIYUN_DMS_LINDORM_URL_TEST|Test Lindorm DMS 页面 URL|"
    "ALIYUN_DMS_REDIS_URL_PROD|Prod Redis DMS 页面 URL(Chrome 兜底)|"
    "ALIYUN_DMS_ES_URL_PROD|Prod ES/Kibana DMS 页面 URL(Chrome 兜底)|"
    "TIPSY_BYTEBASE_URL|Bytebase 页面 URL(401 重授权用)|https://bytebase.infra.fantacy.live"
    "TIPSY_METAMCP_URL|MetaMCP 页面 URL|https://metamcp.fantacy.live"
  )

  # 检查已存在的键
  local missing_keys=()
  for entry in "${keys[@]}"; do
    local k="${entry%%|*}"
    if ! grep -qE "^\s*(export\s+)?${k}=" "$SECRETS_FILE" 2>/dev/null; then
      missing_keys+=("$entry")
    fi
  done

  if [[ ${#missing_keys[@]} -eq 0 ]]; then
    success "secrets.sh 已包含全部 ${#keys[@]} 个 tipsy-oncall 键,无需追加"
    return
  fi

  info "发现 ${#missing_keys[@]}/${#keys[@]} 个键缺失,准备追加..."

  # 检查 marker 块是否已存在
  local has_marker=0
  if grep -qF "$SECRETS_MARKER_BEGIN" "$SECRETS_FILE"; then
    has_marker=1
    info "检测到已有 tipsy-oncall marker 块,只追加缺失键到块内末尾"
  else
    info "未检测到 marker 块,在文件末尾追加整块"
  fi

  # dry-run 模式:只打印要追加的内容
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) 将追加以下键(值留空):"
    for entry in "${missing_keys[@]}"; do
      local k="${entry%%|*}"
      local rest="${entry#*|}"
      local comment="${rest%%|*}"
      local default_val="${rest#*|}"
      info "    # $comment"
      info "    export ${k}=\"${default_val}\""
    done
    return
  fi

  # 实际写入
  if [[ $has_marker -eq 0 ]]; then
    # 完整块追加
    {
      echo ""
      echo "$SECRETS_MARKER_BEGIN"
      echo "# ============================================================"
      for entry in "${missing_keys[@]}"; do
        local k="${entry%%|*}"
        local rest="${entry#*|}"
        local comment="${rest%%|*}"
        local default_val="${rest#*|}"
        echo ""
        echo "# $comment"
        echo "export ${k}=\"${default_val}\""
      done
      echo ""
      echo "$SECRETS_MARKER_END"
    } >> "$SECRETS_FILE"
    success "已在文件末尾追加 tipsy-oncall marker 块(${#missing_keys[@]} 个键)"
  else
    # 在已有 marker 块的 END 之前插入缺失键
    local tmp="${SECRETS_FILE}.tmp.$$"
    local to_add=""
    local entry k rest comment default_val
    for entry in "${missing_keys[@]}"; do
      k="${entry%%|*}"
      rest="${entry#*|}"
      comment="${rest%%|*}"
      default_val="${rest#*|}"
      to_add+=$'\n'"# ${comment}"$'\n'"export ${k}=\"${default_val}\""$'\n'
    done
    awk -v end="$SECRETS_MARKER_END" -v to_add="$to_add" '
      $0 ~ end && !inserted { printf "%s", to_add; inserted=1 }
      { print }
    ' "$SECRETS_FILE" > "$tmp"
    mv "$tmp" "$SECRETS_FILE"
    success "已在 marker 块内追加 ${#missing_keys[@]} 个缺失键"
  fi

  warn "⚠️ 追加的键值均为空(除个别有默认值),请打开 secrets.sh 手动填真实值:"
  warn "  vim $SECRETS_FILE"
  warn "  参考 $SOURCE_DIR/secrets.example.sh"
}

# ============== --replace-legacy ==============
replace_legacy() {
  if [[ $REPLACE_LEGACY -eq 0 ]]; then
    return
  fi

  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info " --replace-legacy: 清理旧的项目级 tipsy-debug skill"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [[ ! -d "$LEGACY_SKILL_DIR" ]]; then
    info "未发现 $LEGACY_SKILL_DIR,无需清理"
    return
  fi

  info "发现旧 skill: $LEGACY_SKILL_DIR"

  # 检查是否在 git 仓库内、有无未提交改动
  if command -v git &>/dev/null && (cd "$(dirname "$LEGACY_SKILL_DIR")" 2>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null); then
    local repo_root
    repo_root="$(cd "$(dirname "$LEGACY_SKILL_DIR")" && git rev-parse --show-toplevel)"
    info "所在仓库: $repo_root"

    local uncommitted
    uncommitted="$(cd "$repo_root" && git status --porcelain -- "$LEGACY_SKILL_DIR" 2>/dev/null || true)"
    if [[ -n "$uncommitted" ]]; then
      warn "⚠️ 旧 skill 有未提交改动:"
      echo "$uncommitted" | sed 's/^/    /'
      if [[ $FORCE -eq 0 ]]; then
        error "拒绝删除有未提交改动的目录。加 --force 强制:  $0 --replace-legacy --force"
        exit 6
      fi
      warn "已指定 --force,继续删除(未提交改动会丢失)"
    else
      success "无未提交改动,可以安全删除"
    fi
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) 会删除:$LEGACY_SKILL_DIR"
    info "(dry-run) 不会动 worktrees、不会动 .agents/、不会动 sync.sh 同步过去的副本"
    return
  fi

  rm -rf "$LEGACY_SKILL_DIR"
  success "已删除 $LEGACY_SKILL_DIR"
  warn "提醒:worktrees 下的副本、~/.agents/skills/tipsy-debug 未动。"
  warn "  如需清理 worktree 里的:cd <worktree>; rm -rf .claude/skills/tipsy-debug"
  warn "  如需清理 ~/.agents 里的:rm -rf ~/.agents/skills/tipsy-debug"
}

# ============== 主流程 ==============
do_install() {
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info " tipsy-oncall · 安装脚本"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  [[ $DRY_RUN -eq 1 ]] && warn "dry-run 模式:不会实际修改文件"

  preflight
  install_skill
  check_runtime_deps
  check_mcps
  append_secrets
  replace_legacy

  echo ""
  if [[ $DRY_RUN -eq 0 ]]; then
    success "✅ 安装完成:tipsy-oncall"
  else
    info "(dry-run) 将安装:tipsy-oncall"
  fi
  echo ""
  info "后续步骤:"
  info "  1. 打开 $SECRETS_FILE,填 tipsy-oncall marker 块里的真实值"
  info "     (参考 $SOURCE_DIR/secrets.example.sh 每个键的说明)"
  info "  2. 验证 MCP:claude mcp list  应看到 4 个 ✓ Connected"
  info "  3. 重启 Claude Code 会话或开新对话,skill 列表应出现 tipsy-oncall"
  info "  4. 触发示例:「查 prod 环境 session xxx 的 mempoint」/「angel 角色为什么消失」"
  echo ""
  info "旧的项目级 skill 未动。如需清理:  $0 --replace-legacy"
}

# ============== 卸载 ==============
do_uninstall() {
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info " tipsy-oncall · 卸载脚本"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  [[ $DRY_RUN -eq 1 ]] && warn "dry-run 模式:不会实际删除"

  local dst="$TARGET_SKILLS/$SKILL_NAME"
  if [[ -e "$dst" ]]; then
    if [[ -f "$dst/$INSTALL_MARKER" ]] || [[ $FORCE -eq 1 ]]; then
      info "[删除] skill $dst"
      [[ $DRY_RUN -eq 0 ]] && rm -rf "$dst"
    else
      warn "[跳过] ${dst}(无安装标记,可能是本地自有 skill;--force 可强删)"
    fi
  else
    info "未安装,无需卸载:$dst"
  fi

  warn "以下项未自动移除(可能被其它 skill 共用):"
  warn "  - MCP:bytebase / signoz / logfire / aliyun-sls"
  warn "  - secrets.sh marker 块(手动删 '$SECRETS_MARKER_BEGIN' 到 '$SECRETS_MARKER_END' 整块)"
  warn "  - ~/.agents/skills/tipsy-oncall(若用 sync.sh 同步过)"

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
