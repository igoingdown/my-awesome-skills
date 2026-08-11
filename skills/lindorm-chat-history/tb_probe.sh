#!/usr/bin/env bash
# 拿到 SK 后第一件事：跑这个，自证 tool-bridge 到底能为「查聊天原文」做什么。
# 不臆断，全部实测。输出一份判定，直接决定 query_chat_history.sh 怎么接 TB。
#
# 背景张力（务必带着这个问题看结果）：
#   本 skill 的核心是「拉聊天【原文】」，而 tool-bridge 手册写着 chatsearch_* 只能
#   count/聚合、禁查正文。所以关键问题是：TB 树上到底有没有一条能拿到【原文/逐字段】的路？
#   —— 有则可接，只能聚合则 TB 仅能替代 --count，原文仍走 lindorm 直连。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TB="bash $HERE/tb_call.sh"
sep(){ printf '\n========== %s ==========\n' "$1"; }

sep "1. 全树概览（受权限裁剪，普通 token 应只见 mcp/plugins/skills）"
$TB tree 2 || true

sep "2. tipsy 源工具索引（找 chatsearch_* / lindorm_* / sls_* / feishu_read_doc）"
$TB help mcp/tipsy 2>/dev/null | { command grep -iE 'chatsearch|lindorm|sls_|content|message|feishu_read' || cat; } | head -60

sep "3. bytebase 只读通道（原文若在 MySQL/PG，可绕过 chatsearch 正文限制）"
$TB help plugins/bytebase 2>/dev/null | head -30

sep "4. 逐个探 chatsearch_* 工具的入参 schema（看返回里有没有原文/正文字段）"
for t in chatsearch_rev_user_id chatsearch_query chatsearch_messages; do
  printf -- '--- %s ---\n' "$t"
  $TB help "mcp/tipsy/$t" 2>/dev/null | head -40 || echo "(该工具名不存在，忽略)"
done

sep "判定要点（人工确认，写回 SKILL.md 与本 skill 的记忆）"
cat <<'EOF'
问自己三个问题，答案决定接线方式：
  A. tree 里是否出现 mcp/tipsy？普通 token 有没有 call 权限？
  B. chatsearch_* / 任一 tipsy 工具的返回是否含【逐条原文/content】字段？
     - 含原文 → query_chat_history.sh 可用 --backend tool-bridge 走 TB。
     - 只给 count/聚合 → TB 仅替代 --count；原文继续 lindorm 直连（默认后端不变）。
  C. bytebase 只读能否直接查到存原文的库表（第六节库定位表）？
     - 能 → 这是「原文 + 绕过 chatsearch 正文限制」的备用路，记进记忆。
把结论写进 SKILL.md 的「## tool-bridge 后端」小节，并更新 chat-content-access-paths 记忆。
EOF
