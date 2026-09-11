#!/bin/bash
# 飞书招聘未评价面试巡检 — 每天 10:30 由 launchd (com.user.hire-patrol) 触发
set -u

export PATH="/Users/zhaomingxing/.nvm/versions/node/v24.15.0/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export LANG=en_US.UTF-8

BASE="/Users/zhaomingxing/hire_patrol"
LOG_DIR="$BASE/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/run-$(date +%Y%m%d-%H%M%S).log"

# 防重入(评估一个候选人可能跑几十分钟)
# ⚠️ 陈旧锁自动接管：原实现只要 mkdir 失败就静默 exit 0，若上一轮被 kill -9 /
# 断电 / OOM 导致 trap 没跑到，锁目录会永久残留，此后每一轮都静默跳过，
# 而且退出码是 0——没有任何告警，任务等于死掉但看起来一切正常。
LOCK="$BASE/.lock"
LOCK_MAX_AGE_MIN=180   # 一轮最长按 3 小时算（多候选人 × 每人 6 路 review）
if ! mkdir "$LOCK" 2>/dev/null; then
  lock_age=$(( ( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || date +%s) ) / 60 ))
  lock_pid="$(cat "$LOCK/pid" 2>/dev/null || echo '')"
  if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null && [[ $lock_age -lt $LOCK_MAX_AGE_MIN ]]; then
    echo "[$(date)] another run in progress (pid $lock_pid, ${lock_age}min), skip" >>"$LOG"
    exit 0
  fi
  echo "[$(date)] 发现陈旧锁 (pid='${lock_pid:-未知}', ${lock_age}min)，接管并告警" >>"$LOG"
  lark-cli im +messages-send --user-id ou_c1ed0ed35fbeaef460c457906f8d31be \
    --markdown "⚠️ 招聘巡检发现陈旧锁(pid=${lock_pid:-未知}, 已存在 ${lock_age} 分钟),本轮已接管。上一轮可能被强杀或崩溃,请看 $LOG" >>"$LOG" 2>&1 || true
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || { echo "[$(date)] 接管锁失败,退出" >>"$LOG"; exit 1; }
fi
echo "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

# 本次要生成评价的候选人目标目录清单(由 prompt.md 在评估阶段逐个写入)
TARGETS="$BASE/last_run_targets.txt"
: >"$TARGETS"   # 每轮开始清空,避免读到上轮残留

echo "[$(date)] patrol start" >>"$LOG"
/opt/homebrew/bin/claude -p "$(cat "$BASE/prompt.md")" \
  --dangerously-skip-permissions \
  >>"$LOG" 2>&1
CLAUDE_EXIT=$?
echo "[$(date)] patrol exit=$CLAUDE_EXIT" >>"$LOG"

# patrol 自身失败 → 必须独立告警。
# 真实事故 2026-09-07：claude -p 因 ConnectionRefused 崩溃(exit=1),清单自然为空,
# verify 把空清单判成"今日无未评价面试"正常退出(exit=0),告警条件不成立 ——
# 当天有一场真实面试没被采集,失败被伪装成"没活干"。
# 空清单只有在 patrol 成功退出时才代表"确实无未评价面试"。
if [[ $CLAUDE_EXIT -ne 0 ]]; then
  TAIL_LOG="$(tail -20 "$LOG")"
  MSG="🚨 招聘巡检失败:patrol 进程异常退出(exit=$CLAUDE_EXIT),本次未采集任何候选人。"$'\n'"日志尾部："$'\n'"\`\`\`"$'\n'"$TAIL_LOG"$'\n'"\`\`\`"$'\n'"需人工确认今日是否有未评价面试:$LOG"
  lark-cli im +messages-send --user-id ou_c1ed0ed35fbeaef460c457906f8d31be --markdown "$MSG" >>"$LOG" 2>&1 \
    && echo "[$(date)] patrol-fail alert sent" >>"$LOG" \
    || echo "[$(date)] patrol-fail alert send FAILED" >>"$LOG"
fi

# 收尾校验:确认每个应生成评价的候选人目录都产出了完整报告
# (真实教训:claude -p 可能在评估未完成时就退出,采集完但报告缺失)
echo "[$(date)] verify start" >>"$LOG"
VERIFY_OUT="$("$BASE/verify.sh" "$TARGETS" "$CLAUDE_EXIT" 2>&1)"
VERIFY_EXIT=$?
echo "$VERIFY_OUT" >>"$LOG"
echo "[$(date)] verify exit=$VERIFY_EXIT" >>"$LOG"

# 有缺失或内容门禁未过 → 发飞书告警(补一条,不依赖 claude 进程自身是否记得发)
if [[ $VERIFY_EXIT -ne 0 ]]; then
  MISS_LINES="$(printf '%s\n' "$VERIFY_OUT" | grep -E '\[MISS\]|\[GATE\]')"
  MSG="⚠️ 招聘巡检收尾校验未过,需人工处理："$'\n'"$MISS_LINES"
  lark-cli im +messages-send --user-id ou_c1ed0ed35fbeaef460c457906f8d31be --markdown "$MSG" >>"$LOG" 2>&1 \
    && echo "[$(date)] alert sent" >>"$LOG" \
    || echo "[$(date)] alert send FAILED" >>"$LOG"
fi

# ============ 多路独立 review（发布门禁）============
# 为什么必须做：AI 自查查不出自己的系统性偏差。真实事故——
#   2026-09-07 把手写编造的"正确解"当程序输出写进报告，外部 review 才发现
#   2026-09-08 自创"正负相抵"绕过评分规则，导致交付错误代码的人分数高于零输出的人
#   2026-09-08 连续三份用 A-/B+/B- 等未定义档位
# 通过 verify 只说明格式与门禁词合格，不说明结论正确，所以再加一道独立复核。
REVIEW_TARGETS=""
if [[ -s "$TARGETS" ]]; then
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    [[ -s "$d/evaluation.md" && -s "$d/interviewer-review.md" ]] && REVIEW_TARGETS+="$d"$'\n'
  done < "$TARGETS"
fi

if [[ -n "$(echo "$REVIEW_TARGETS" | tr -d '[:space:]')" ]]; then
  echo "[$(date)] multi-review start" >>"$LOG"
  REVIEW_FAIL=""
  # 候选人之间串行（每人内部已 6 路并发，再叠加会打满 CPU 与网关配额）
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    name="$(basename "$(dirname "$d")")/$(basename "$d")"
    if "$BASE/multi-review.sh" "$d" >>"$LOG" 2>&1; then
      echo "[$(date)] review OK: $name" >>"$LOG"
    else
      echo "[$(date)] review 高危 findings: $name" >>"$LOG"
      REVIEW_FAIL+="  $name → $d/review/SUMMARY.md"$'\n'
    fi
  done <<EOF
$REVIEW_TARGETS
EOF

  if [[ -n "$REVIEW_FAIL" ]]; then
    MSG="🔍 多路 review 发现高危问题,评价**先不要对外提交**,请先看 SUMMARY 并改判："$'\n'"$REVIEW_FAIL"
    lark-cli im +messages-send --user-id ou_c1ed0ed35fbeaef460c457906f8d31be --markdown "$MSG" >>"$LOG" 2>&1 \
      && echo "[$(date)] review alert sent" >>"$LOG" \
      || echo "[$(date)] review alert send FAILED" >>"$LOG"
  fi
  echo "[$(date)] multi-review done" >>"$LOG"
fi

# 只保留最近 30 天日志（review 目录不清，属评价档案的一部分）
find "$LOG_DIR" -name 'run-*.log' -mtime +30 -delete 2>/dev/null
