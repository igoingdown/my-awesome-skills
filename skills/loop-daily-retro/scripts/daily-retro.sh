#!/usr/bin/env bash
# 每日复盘循环：分析【昨天】的 Claude session（+ 可选 IM 素材），用 headless claude 生成
# 「日记 + 自我改进项」云文档，并维护一篇累积改进计划文档，最后把日记链接推一条通知。
#
# 这是一个参考实现（去敏版）。文档层（$DOC_CLI）、通知层（$NOTIFY_CMD）、IM 素材层
# （$IM_DIGEST_CMD）都需你换成自己的实现。
#
# 触发：crontab 每天上午。日志：~/.local/var/daily-retro.log
# 手动补跑某天： daily-retro.sh 2026-08-06
set -uo pipefail

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

CONFIG="${LOOP_DAILY_RETRO_CONFIG:-$HOME/.config/loop-daily-retro.sh}"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && source "$CONFIG"

REPORT_OWNER="${REPORT_OWNER:-Me}"
NOTIFY_CMD="${NOTIFY_CMD:-}"
DOC_CLI="${DOC_CLI:-doc-cli}"
export IM_DIGEST_CMD="${IM_DIGEST_CMD:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIGEST_PY="$SCRIPT_DIR/digest.py"

LOG_DIR="$HOME/.local/var"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/daily-retro.log"
exec >>"$LOG" 2>&1

notify() { [ -n "$NOTIFY_CMD" ] && "$NOTIFY_CMD" "$1" >/dev/null 2>&1 || echo "notify: $1"; }

# 目标日期：参数优先，否则昨天
DAY="${1:-$(date -d yesterday +%F)}"
echo "===== daily retro run $(date -Is)  day=$DAY ====="

# 累积改进计划文档 token 存这，第一次运行为空、后续复用同一篇
PLAN_TOKEN_FILE="$LOG_DIR/daily-retro-plan-token"
PLAN_TOKEN="$(cat "$PLAN_TOKEN_FILE" 2>/dev/null || true)"

DIGEST=$(mktemp /tmp/daily-retro-digest-XXXX.txt)
trap 'rm -f "$DIGEST"' EXIT
python3 "$DIGEST_PY" "$DAY" > "$DIGEST"
echo "digest: $(wc -l < "$DIGEST") lines, $(wc -c < "$DIGEST") bytes"

# 判空：PART 1 里没有任何 session（"共 0 个"）→ 当天无活动，静默但仍发一行提示
if command grep -q '共 0 个' "$DIGEST"; then
  notify "🗓️ 每日复盘（$DAY）：昨天没有检测到 Claude session 活动，跳过。"
  echo "no session activity, skipped."
  echo "===== done $(date -Is) ====="
  exit 0
fi

TITLE="日报复盘 $DAY（$REPORT_OWNER）"
PLAN_HINT=""
if [ -n "$PLAN_TOKEN" ]; then
  PLAN_HINT="已有一篇累积改进计划文档（token: $PLAN_TOKEN）。读它，把今天的新改进项【追加】到顶部（保留历史），不要重写整篇。"
else
  PLAN_HINT="还没有累积改进计划文档。请新建一篇，标题「自我改进计划（$REPORT_OWNER · 持续累积）」，写入今天的改进项作为第一天。创建后把它的 doc token 打印成一行：PLAN_TOKEN=<token>，我会存起来供明天追加。"
fi

PROMPT="你是 $REPORT_OWNER 的每日复盘助手。文件 $DIGEST 是 TA【$DAY】当天的工作素材，已经把该看的内容都提取好了，**直接通读这个文件即可，不要去 Read 任何原始 transcript（那些文件十几 MB，读了会超时）**：
- PART 1：当天有真实活动的所有 session。标了 [TOP] 的前 3 个已内联当天较完整对话正文（用户提问全文 + 助手每轮首段），据此判断'最难的事、如何优化'；其余 session 只有摘要，够用。
- PART 2：当天 IM 素材（若已接入）。往往是 TA 的想法、自我批评、或被交办的事，重点看。

任务一：写一份【日记】，1000 字以内（不要太详细也不要过于简单），中文，围绕这五个问题，用第一人称视角：
1. 最耗时间的事是什么？
2. 最困难的事是什么？
3. 做了什么把这些问题优化了？
4. 有哪些可以沉淀和改进的地方？
5. IM 素材（PART 2）里有什么想法或自我批评？（没接入 IM 就跳过这条）
日记末尾附一节「今日自我改进项」，3 条以内，具体可执行。

任务二：维护累积改进计划。$PLAN_HINT

硬约束：
- 所有数字、结论、PR 号必须来自素材文件，不要编造；测试性 session（如 skill 优化 headless、'Reply with exactly'）和纯生活类内容忽略。
- 先学习 $DOC_CLI 用法，用它建/改云文档。日记文档标题「$TITLE」。
- 日记文档创建成功后，用 $NOTIFY_CMD 把【日记文档链接 + 一句话当天摘要】发出去。
- 如果这是第一次运行、你新建了累积改进计划文档，务必在最终输出里单独打印一行 PLAN_TOKEN=<token>。"

OUT=$(mktemp /tmp/daily-retro-out-XXXX.txt)
claude -p "$PROMPT" \
  --allowedTools "Bash,Read,Write,Grep,Glob" \
  --max-turns 30 </dev/null | tee "$OUT" \
  || notify "❌ 每日复盘（$DAY）自动生成失败，请查看 $LOG 后手动补跑：daily-retro.sh $DAY"

# 若首次运行拿到了累积改进计划文档 token，存下来供明天追加
if [ -z "$PLAN_TOKEN" ]; then
  NEW_TOKEN=$(command grep -oE 'PLAN_TOKEN=[A-Za-z0-9]+' "$OUT" | head -1 | cut -d= -f2)
  if [ -n "$NEW_TOKEN" ]; then
    echo "$NEW_TOKEN" > "$PLAN_TOKEN_FILE"
    echo "saved plan token: $NEW_TOKEN"
  fi
fi
rm -f "$OUT"

echo "===== done $(date -Is) ====="
