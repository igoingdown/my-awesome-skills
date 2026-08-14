#!/usr/bin/env bash
# 拿到 SK 后第一件事：跑这个，自证 tool-bridge 到底能为「查聊天原文」做什么。
# 不臆断，全部实测。输出一份判定，直接决定 query_chat_history.sh 怎么接 TB。
#
# 背景张力（务必带着这个问题看结果）：
#   本 skill 的核心是「拉聊天【原文】」，而搜索侧的计数/聚合工具往往只能 count/聚合、禁查正文。
#   所以关键问题是：网关树上到底有没有一条能拿到【原文/逐字段】的路？
#   —— 有则可接，只能聚合则网关仅能替代 --count，原文仍走 lindorm 直连。
#
# 源路径按你自己的网关部署填 env（不写死任何组织的真实源名）：
#   TB_CHAT_SOURCE  聊天数据源在网关树里的路径（如 mcp/<你的源>）
#   TB_DB_SOURCE    只读查库源的路径（如 plugins/<你的只读查库源>）
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TB="bash $HERE/tb_call.sh"
CHAT_SRC="${TB_CHAT_SOURCE:-mcp/<your-chat-source>}"
DB_SRC="${TB_DB_SOURCE:-plugins/<your-readonly-db-source>}"
sep(){ printf '\n========== %s ==========\n' "$1"; }

sep "1. 全树概览（受权限裁剪）"
$TB tree 2 || true

sep "2. 聊天数据源工具索引（找计数/查询/日志/文档读取类工具）"
$TB help "$CHAT_SRC" 2>/dev/null | { command grep -iE 'search|query|count|content|message|read' || cat; } | head -60

sep "3. 只读查库通道（原文若在 MySQL/PG，可绕过搜索侧的正文限制）"
$TB help "$DB_SRC" 2>/dev/null | head -30

sep "4. 逐个探候选检索工具的入参 schema（看返回里有没有原文/正文字段）"
for t in ${TB_PROBE_TOOLS:-}; do
  printf -- '--- %s ---\n' "$t"
  $TB help "$CHAT_SRC/$t" 2>/dev/null | head -40 || echo "(该工具名不存在，忽略)"
done
[[ -z "${TB_PROBE_TOOLS:-}" ]] && echo "(设 TB_PROBE_TOOLS='toolA toolB' 指定要逐个探的候选工具名)"

sep "判定要点（人工确认，写回 SKILL.md 与本 skill 的记忆）"
cat <<'EOF'
问自己三个问题，答案决定接线方式：
  A. tree 里是否出现你的聊天数据源？当前 token 有没有 call 权限？
  B. 检索/查询工具的返回是否含【逐条原文/content】字段？
     - 含原文 → query_chat_history.sh 可用 --backend tool-bridge 走网关。
     - 只给 count/聚合 → 网关仅替代 --count；原文继续 lindorm 直连（默认后端不变）。
  C. 只读查库能否直接查到存原文的库表？
     - 能 → 这是「原文 + 绕过搜索侧正文限制」的备用路，记进本地笔记。
把结论写进 SKILL.md 的「## tool-bridge 后端」小节，并把真实工具名填进 secrets 的 LINDORM_TB_*。
EOF
