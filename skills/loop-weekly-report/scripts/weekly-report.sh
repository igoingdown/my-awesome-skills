#!/usr/bin/env bash
# 每周一由 crontab 触发：分析上周（周一~周日）的 Claude session，用 headless claude
# 生成一篇周报云文档，把链接归档进汇总索引文档，并推一条通知。
#
# 这是一个参考实现（去敏版）。文档平台相关的命令（$DOC_CLI）和通知（$NOTIFY_CMD）
# 需要你换成自己的实现——参考实现依赖一个私有的云文档 CLI，不随仓库分发。
#
# 依赖：python3、claude（headless）、$DOC_CLI、$NOTIFY_CMD、scripts/digest.py
# 日志：~/.local/var/weekly-report.log
set -uo pipefail

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

CONFIG="${LOOP_WEEKLY_REPORT_CONFIG:-$HOME/.config/loop-weekly-report.sh}"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && source "$CONFIG"

REPORT_OWNER="${REPORT_OWNER:-Me}"
DOC_TENANT_HOST="${DOC_TENANT_HOST:-}"
INDEX_DOC="${WEEKLY_INDEX_DOC:-}"
INDEX_ANCHOR_KW="${WEEKLY_INDEX_ANCHOR_KW:-[[ANCHOR:weekly-index]]}"
NOTIFY_CMD="${NOTIFY_CMD:-}"
DOC_CLI="${DOC_CLI:-doc-cli}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIGEST_PY="$SCRIPT_DIR/digest.py"

LOG_DIR="$HOME/.local/var"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/weekly-report.log"
exec >>"$LOG" 2>&1

notify() { [ -n "$NOTIFY_CMD" ] && "$NOTIFY_CMD" "$1" >/dev/null 2>&1 || echo "notify: $1"; }

echo "===== weekly report run $(date -Is) ====="

# 上周窗口：[上周一, 本周一)
START=$(date -d "last monday - 7 days" +%F)
END=$(date -d "last monday" +%F)
# 周一当天运行时 "last monday" 是 7 天前，需修正为今天
if [ "$(date +%u)" = "1" ]; then
  START=$(date -d "-7 days" +%F)
  END=$(date +%F)
fi
echo "window: [$START, $END)"

DIGEST=$(mktemp /tmp/weekly-digest-XXXX.txt)
trap 'rm -f "$DIGEST"' EXIT
python3 "$DIGEST_PY" "$START" "$END" > "$DIGEST"
echo "digest: $(wc -l < "$DIGEST") lines"

if [ ! -s "$DIGEST" ]; then
  notify "⚠️ 周报生成跳过：$START ~ $END 窗口内没有找到任何 Claude session。"
  exit 0
fi

WEEK_LABEL="$START ~ $(date -d "$END - 1 day" +%F)"

PROMPT="你是我的周报助手。文件 $DIGEST 是我上周（$WEEK_LABEL）所有 Claude session 的摘要清单。每条含：项目、时间、PR/ISSUE 号、采样的多条用户消息（USER_MSGS，已去重按首/中/末采样）、助手正文高信号行（SIGNAL_LINES）、子代理关键词命中（SUBAGENT_HITS）、最终结论（LAST_ASSIST）。

任务：
1. 通读该文件，把上周的工作按以下大类归纳：需求承接、稳定性问题排查、用户反馈解决、架构设计、基础组件/SDK 设计、研发效能提升（某类没有内容就省略该节；个人生活类内容直接略去）。每项写清：解决了什么问题、拿到了什么结果、后续要做什么。注意 USER_MSGS/SIGNAL_LINES/SUBAGENT_HITS 里藏着长会话和续接会话的主线，不要只看首条消息；SUBAGENT_HITS 命中高的关键词往往是该 session 的真正重头工作。
2. 总结成约 1000~1500 字的中文周报，末尾加一段「下周重点」。
3. 用 $DOC_CLI 创建一篇云文档（先阅读它的用法，标题格式「周报 $WEEK_LABEL（$REPORT_OWNER）」）。
4. 创建成功后，用 $NOTIFY_CMD 把文档链接和一句话摘要发给我。
5. 最后，把新文档的完整 URL 用单独一行输出到 stdout，严格格式：WEEKLY_DOC_URL=<url>（这一行供脚本捕获，不要省略、不要加其它字符）。
注意：数字和结论必须来自摘要文件，不要编造；元操作类 session（讨论周报本身、resume 历史 session）不计入工作量；测试性 session 和空 session 忽略。"

CLAUDE_OUT=$(mktemp /tmp/weekly-claude-out-XXXX.txt)
trap 'rm -f "$DIGEST" "$CLAUDE_OUT"' EXIT

if claude -p "$PROMPT" \
     --allowedTools "Bash,Read,Write,Grep,Glob" \
     --max-turns 60 </dev/null | tee "$CLAUDE_OUT"; then
  DOC_URL=$(grep -oE 'WEEKLY_DOC_URL=\S+' "$CLAUDE_OUT" | tail -1 | cut -d= -f2-)
  if [ -n "$DOC_URL" ]; then
    echo "captured doc url: $DOC_URL"
    if ! "$SCRIPT_DIR/archive-to-index.sh" "$DOC_URL" "$WEEK_LABEL"; then
      notify "⚠️ 周报已生成（$DOC_URL）但写入汇总索引失败，请手动补录。"
    fi
  else
    echo "WARN: 未捕获到 WEEKLY_DOC_URL，跳过索引归档"
    notify "⚠️ 周报已生成但未捕获到链接，无法自动写入汇总索引，请查看日志 $LOG"
  fi
else
  notify "❌ 本周周报自动生成失败，请查看日志 $LOG 后手动补跑：weekly-report.sh"
fi

echo "===== done $(date -Is) ====="
