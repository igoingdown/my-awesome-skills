#!/usr/bin/env bash
# bug-triage-loop install script.
#
# Complements ../../sync.sh (which only copies the skill directory).
# This script owns "how to install THIS skill":
#   - doctor:      check host env, credentials, dependent skills, config
#   - init-config: interactively fill the 3 FILL_ME slots in docs/config.md
#   - uninstall:   remove the skill from ~/.claude/skills and ~/.agents/skills
#
# Long-form porting notes stay in INSTALL.md next to this file.

set -euo pipefail

SKILL_NAME="bug-triage-loop"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_TARGETS=(
  "$HOME/.claude/skills/$SKILL_NAME"
  "$HOME/.agents/skills/$SKILL_NAME"
)

# ---------- output helpers ----------

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

ok()   { echo "${GREEN}✓${NC} $*"; }
fail() { echo "${RED}✗${NC} $*"; }
warn() { echo "${YELLOW}!${NC} $*"; }
info() { echo "${BLUE}→${NC} $*"; }

usage() {
  cat <<EOF
Usage: $0 [command]

Commands:
  doctor         检查安装环境 (CLI / lark-cli auth / secrets env / 依赖 skill /
                 本 skill 已装 / docs/config.md 必填 / MCP 提示) —— 默认命令
  init-config    交互式引导填写 docs/config.md 的 3 个必填字段
                 (bug_chat_id / my_open_id / github_root)
  uninstall      从 ~/.claude/skills/ 和 ~/.agents/skills/ 移除本 skill
                 (不删本仓源码,不删 state/,不删凭证)
  --help, -h     本帮助

Exit codes: 0 = ok / warn, 1 = usage error, 2 = doctor fail

详细安装 / 移植手册见同目录 INSTALL.md。
EOF
}

# ---------- doctor ----------

cmd_doctor() {
  local pass=0 warn_n=0 fail_n=0

  echo "== doctor: 检查 $SKILL_NAME 装机环境 =="
  echo ""

  # 1. CLI 依赖
  echo "-- 1. CLI 依赖"
  for cli in claude lark-cli git jq python3; do
    if command -v "$cli" >/dev/null 2>&1; then
      ok "$cli: $(command -v "$cli")"
      pass=$((pass + 1))
    else
      fail "$cli: 不在 PATH"
      fail_n=$((fail_n + 1))
    fi
  done
  echo ""

  # 2. lark-cli 认证
  echo "-- 2. lark-cli 认证"
  if command -v lark-cli >/dev/null 2>&1; then
    local status_json token_status
    status_json=$(LARKSUITE_CLI_NO_UPDATE_NOTIFIER=1 LARKSUITE_CLI_NO_SKILLS_NOTIFIER=1 \
      lark-cli auth status --json --verify 2>/dev/null || echo '{}')
    token_status=$(printf '%s' "$status_json" | python3 -c \
      'import sys,json; d=json.load(sys.stdin) if sys.stdin.read() else {}; print(d.get("identities",{}).get("user",{}).get("tokenStatus","missing"))' \
      2>/dev/null || echo "unknown")
    case "$token_status" in
      valid)
        ok "lark-cli user token: valid"
        pass=$((pass + 1))
        ;;
      expired)
        warn "lark-cli user token: expired —— 跑 lark-cli auth login --domain all"
        warn_n=$((warn_n + 1))
        ;;
      missing|unknown|"")
        fail "lark-cli user token: 未登录或状态未知 —— 跑 lark-cli auth login --domain all"
        fail_n=$((fail_n + 1))
        ;;
      *)
        warn "lark-cli auth status 输出异常 (tokenStatus=$token_status)"
        warn_n=$((warn_n + 1))
        ;;
    esac
  else
    warn "lark-cli 不在 PATH —— 跳过 auth 检查"
    warn_n=$((warn_n + 1))
  fi
  echo ""

  # 3. secrets.sh 相关环境变量 (给 MCP 用)
  echo "-- 3. secrets.sh 环境变量 (MCP 需要, 缺则相关证据源降级)"
  # 以下环境变量名是作者项目里的例子。如果你的 secrets.sh 用别的名字,
  # 直接改这个数组即可。变量本身不进 skill 目录,只在这里做 doctor 断言。
  local secret_keys=(
    ALIYUN_SLS_AK_ID
    ALIYUN_SLS_ENDPOINT
    ALIYUN_SLS_PROJECT
    BYTEBASE_URL
  )
  for k in "${secret_keys[@]}"; do
    if [[ -n "${!k-}" ]]; then
      ok "$k: 已 export (值屏蔽)"
      pass=$((pass + 1))
    else
      warn "$k: 未 export"
      warn_n=$((warn_n + 1))
    fi
  done
  echo ""

  # 4. 依赖 skill
  echo "-- 4. 依赖 skill"
  local required_skills=(lark-im lark-contact lark-shared)
  local optional_skills=(lark-event)
  for dep in "${required_skills[@]}"; do
    if [[ -f "$HOME/.claude/skills/$dep/SKILL.md" ]]; then
      ok "$dep: 已装 (~/.claude/skills/$dep)"
      pass=$((pass + 1))
    else
      fail "$dep: 未装 (硬依赖, 缺则飞书功能失败)"
      fail_n=$((fail_n + 1))
    fi
  done
  for opt in "${optional_skills[@]}"; do
    if [[ -f "$HOME/.claude/skills/$opt/SKILL.md" ]]; then
      ok "$opt: 已装 (可选)"
      pass=$((pass + 1))
    else
      warn "$opt: 未装 (可选, 长时事件订阅会用到)"
      warn_n=$((warn_n + 1))
    fi
  done
  echo ""

  # 5. 本 skill 是否已装到全局
  echo "-- 5. 本 skill 是否已装"
  for target in "${INSTALL_TARGETS[@]}"; do
    if [[ -f "$target/SKILL.md" ]]; then
      ok "$target: 已装"
      pass=$((pass + 1))
    else
      warn "$target: 未装 —— 回到仓根跑 ./sync.sh $SKILL_NAME"
      warn_n=$((warn_n + 1))
    fi
  done
  echo ""

  # 6. docs/config.md 必填字段
  echo "-- 6. docs/config.md 必填字段"
  local config="$SCRIPT_DIR/docs/config.md"
  if [[ ! -f "$config" ]]; then
    fail "$config: 不存在"
    fail_n=$((fail_n + 1))
  else
    local required_keys=(bug_chat_id my_open_id github_root)
    for key in "${required_keys[@]}"; do
      local line
      line=$(grep -E "^${key}:" "$config" 2>/dev/null | head -1 || true)
      if [[ -z "$line" ]]; then
        fail "config.md 缺 ${key}: 行"
        fail_n=$((fail_n + 1))
      elif echo "$line" | grep -q FILL_ME; then
        warn "config.md ${key}: 仍是 FILL_ME —— 跑 ./install.sh init-config"
        warn_n=$((warn_n + 1))
      else
        ok "config.md ${key}: 已填"
        pass=$((pass + 1))
      fi
    done
  fi
  echo ""

  # 7. MCP servers (只提示, 深度验证需要在 Claude Code 里跑)
  echo "-- 7. MCP servers (信息性)"
  info "aliyun-sls / bytebase / signoz / logfire 需要在 Claude Code 侧配置 MCP"
  info "验证: 进 Claude Code, 让它跑 mcp__aliyun-sls__sls_list_projects 或类似只读工具"
  echo ""

  # 汇总
  echo "== 汇总: pass=$pass warn=$warn_n fail=$fail_n =="
  if (( fail_n > 0 )); then
    echo "${RED}✗ 有 $fail_n 项 fail —— 请修复上面 ✗ 的问题${NC}"
    return 2
  elif (( warn_n > 0 )); then
    echo "${YELLOW}! 有 $warn_n 项 warn —— 可选依赖或非致命警告, skill 可运行但功能会降级${NC}"
    return 0
  else
    echo "${GREEN}✓ 全部通过${NC}"
    return 0
  fi
}

# ---------- init-config ----------

cmd_init_config() {
  local config="$SCRIPT_DIR/docs/config.md"
  if [[ ! -f "$config" ]]; then
    fail "docs/config.md 不存在: $config"
    return 1
  fi

  echo "== init-config: 交互式引导填写 docs/config.md 的 3 个必填字段 =="
  echo "留空 = 保留当前值不改。"
  echo ""

  local backup
  backup="$config.bak.$(date +%s)"
  cp "$config" "$backup"
  info "已备份原文件到 $backup"
  echo ""

  # 用两个数组代替 associative array (提高对 bash 3.2 的兼容性)
  local -a keys=(bug_chat_id my_open_id github_root)
  local -a hints=(
    "飞书 Bug 群 chat_id (格式 oc_xxx). 用 lark-cli im +chat-search --query bug --as user 查"
    "你自己的 open_id (格式 ou_xxx). 用 lark-cli contact +get-user --as user --json 查"
    "你的 GitHub 工作目录绝对路径, 如 /Users/xxx/github 或 /root/github"
  )

  local i
  for i in "${!keys[@]}"; do
    local key="${keys[$i]}"
    local hint="${hints[$i]}"
    local cur new_val
    cur=$(grep -E "^${key}:" "$config" 2>/dev/null | head -1 | sed -E "s/^${key}:[[:space:]]*//" || true)
    echo "-- ${key}"
    echo "   ${hint}"
    echo "   当前值: ${cur:-<空>}"
    read -r -p "   新值 (留空保留当前): " new_val
    if [[ -n "$new_val" ]]; then
      python3 - "$config" "$key" "$new_val" <<'PY'
import re, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
pat = re.compile(rf'^({re.escape(key)}:)[^\n]*', re.M)
if not pat.search(text):
    print(f'error: key {key} not found in {path}', file=sys.stderr)
    sys.exit(1)
new = pat.sub(rf'\1 {val}', text, count=1)
open(path, 'w').write(new)
PY
      ok "$key: 已写入"
    else
      info "$key: 跳过"
    fi
    echo ""
  done

  echo "完成。跑 ./install.sh doctor 复查。"
}

# ---------- uninstall ----------

cmd_uninstall() {
  echo "== uninstall: 从全局 skill 目录移除 $SKILL_NAME =="
  echo ""
  info "将删除以下路径 (若存在):"
  for target in "${INSTALL_TARGETS[@]}"; do
    echo "  - $target"
  done
  echo ""
  info "不会动: 本仓源码 / state/ 目录 / secrets.sh / lark-cli 认证"
  echo ""
  read -r -p "确认?[y/N] " confirm
  case "$confirm" in
    y|Y|yes|YES)
      for target in "${INSTALL_TARGETS[@]}"; do
        if [[ -d "$target" ]]; then
          rm -rf "$target"
          ok "已删 $target"
        else
          info "$target 不存在, 跳过"
        fi
      done
      echo ""
      warn "state/ 目录 (若单独存在, 含真实事故内容) 未删, 请手动决定是否清理"
      warn "凭证 (secrets.sh / ~/.lark-cli) 未删, 可能其他 skill 也在用"
      ;;
    *)
      info "取消"
      ;;
  esac
}

# ---------- dispatch ----------

case "${1:-doctor}" in
  doctor)
    cmd_doctor
    ;;
  init-config)
    cmd_init_config
    ;;
  uninstall)
    cmd_uninstall
    ;;
  --help|-h)
    usage
    ;;
  *)
    fail "unknown command: $1"
    echo ""
    usage
    exit 1
    ;;
esac
