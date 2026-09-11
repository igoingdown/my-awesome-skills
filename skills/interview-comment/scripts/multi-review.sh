#!/bin/bash
# multi-review.sh — 面试评价的多路独立 review（发布门禁）
#
# 用途：评价生成后，用多个独立模型并行复核，产出 findings 供改判。
# 设计依据（真实事故 2026-09-07 / 09-08）：
#   - AI 曾把手写编造的"正确解"当成程序输出写进报告，外部 review 才发现
#   - AI 曾自创"正负相抵"绕过评分规则，导致判分倒挂（交付错误代码的人分数高于零输出的人）
#   - AI 曾连续三份用 A-/B+/B- 等未定义档位
# 这些都是自查查不出来的——同一个模型不会发现自己的系统性偏差，必须外部独立复核。
#
# 用法：
#   multi-review.sh <候选人目录> [轮次目录名]
#   multi-review.sh ~/github/interviews/liulei/001
#   multi-review.sh ~/github/interviews/liulei/001 --models "gpt-5.6-sol,gpt-5.6-terra"
#
# 输出：<目录>/review/<model>-<pass>.md + <目录>/review/SUMMARY.md
# 退出码：0=全部通过或仅低危 findings；1=有高危 findings 需改判；2=参数/环境错误

set -uo pipefail

TARGET="${1:-}"
if [[ -z "$TARGET" || ! -d "$TARGET" ]]; then
  echo "用法: multi-review.sh <候选人轮次目录> [--models m1,m2]" >&2
  exit 2
fi
TARGET="$(cd "$TARGET" && pwd)"

MODELS="gpt-5.6-sol,gpt-5.6-terra,gpt-5.6-luna"
if [[ "${2:-}" == "--models" && -n "${3:-}" ]]; then MODELS="$3"; fi

CODEX="/opt/homebrew/bin/codex"
[[ -x "$CODEX" ]] || { echo "codex 不可用: $CODEX" >&2; exit 2; }
export PATH="/opt/homebrew/bin:$PATH"

SKILL_DIR="$HOME/github/my-awesome-skills/skills/interview-comment"
REVIEW_DIR="$TARGET/review"
mkdir -p "$REVIEW_DIR"

# 必备材料检查——缺材料时 review 会退化成猜测
for f in evaluation.md interviewer-review.md asr.md; do
  [[ -s "$TARGET/$f" ]] || { echo "缺少 ${f}，不启动 review" >&2; exit 2; }
done

# 陈旧 review 文件自动归档（事故 2026-09-11）
# 下面的等待循环用「文件非空」判定某路是否产出，不看 mtime。若目录里残留上一版
# 报告的 review 文件，循环会立刻判定已达多数、6 分钟宽限后杀掉正在跑的进程，
# 并把「旧结论」汇总进 SUMMARY.md —— 看起来 review 过了，实际复核的是旧报告。
# 判定口径：任一 *-pass*.md 比 evaluation.md 更旧，说明报告已重写过，整批作废。
stale=0
for f in "$REVIEW_DIR"/*-pass*.md; do
  [[ -e "$f" ]] || continue
  [[ "$f" -ot "$TARGET/evaluation.md" ]] && stale=1
done
if [[ $stale -eq 1 ]]; then
  ARCHIVE="$TARGET/review-stale-$(cd "$TARGET" && stat -f %m evaluation.md)"
  echo "发现比 evaluation.md 更旧的 review 文件（报告已重写），归档到 $(basename "$ARCHIVE")"
  mkdir -p "$ARCHIVE"
  for f in "$REVIEW_DIR"/*.md "$REVIEW_DIR"/.*.log; do
    [[ -e "$f" ]] && mv "$f" "$ARCHIVE"/ 2>/dev/null
  done
fi

CAND="$(basename "$(dirname "$TARGET")")"
ROUND="$(basename "$TARGET")"

# 两个 pass 的侧重不同，避免三个模型给出同质化结论
PASS1_FOCUS='本轮重心【事实核查 + 评分逻辑】：(1) 编程题实跑结论是否可复现——若有 candidate-code，自己实际编译运行验证，不要相信报告里的实测结论；(2) 六维标注与综合分的推导链是否符合 scoring-rubric 的决策表顺序，特别检查有没有把硬负向证据藏进 = 里、有没有使用"正负相抵"这类规则外表述、编码形态 C0~C4 判定是否正确；(3) 抽查报告引用与 asr.md 原文是否一致（挑 5-8 处关键引语核对即可，不必逐条通读全文）。
⚠️ 执行顺序要求：先做 (1)(2) 并**立即把已得结论写入输出文件**，再回头做 (3) 补充。历史上有一路因为先通读完整转写而耗尽时间预算、最后一个字都没写出来，白跑一轮。宁可先交一份只覆盖 (1)(2) 的结论，也不要交空文件。'
PASS2_FOCUS='本轮扮演【对抗性审查者】：假设这份报告会被候选人本人和 HR 看到并可能被质疑。逐条攻击每个结论——哪些判断经不起追问？哪些证据强度不足以支撑措辞？哪些地方把推测包装成了候选人的缺陷？同时也要指出反方向的问题：哪些地方过于宽松、放过了真实缺陷。检查对外交付物 evaluation.md 有没有混入内部术语、断链文件引用、未定义档位。'

BRIEF="$REVIEW_DIR/_brief.md"
cat > "$BRIEF" <<EOF
# Review 任务

候选人 ${CAND}，第 ${ROUND} 轮。你要 review 的是 AI 用 interview-comment skill 生成的面试评价。

## 材料位置（全部为绝对路径）
- 完整语音转写：$TARGET/asr.md
- 简历：$TARGET/resume.png（视觉）
- 候选人评价（对外交付物，会被整段贴进公司招聘系统）：$TARGET/evaluation.md
- 面试官复盘：$TARGET/interviewer-review.md
- 编程题分析（若有）：$TARGET/coding-analysis.md
- 候选人代码（若有）：$TARGET/candidate-code.*
- 评分规则：$SKILL_DIR/references/scoring-rubric.md
- 主 skill：$SKILL_DIR/SKILL.md
- 面试官档位规则：$SKILL_DIR/references/interviewer-rubric.md

## 硬性检查项（必答，逐条给结论）
1. **综合分是否正确**：按 scoring-rubric「六维→综合分决策表」的顺序机械复算。核心维度（技术支撑/技术深度/编码与算法）出现 \`-\` 时综合必须 ≤2.5，不得因其他维度有 \`+\` 而上浮。给出你复算的六维标注与综合分。
2. **编码形态判定是否正确**：按状态机 C0~C4 判。C0（未形成可验收主体且被面试官打断）留空；C1（充分取样零输出）判 \`-\`；C2（有主体但实测错）判 \`-\`。检查有没有把 C2 误判成 C0 或 \`=\`。
3. **有 candidate-code 时必须自己实跑**：不要相信报告里的实测结论，自己编译运行，用题面全部用例 + 至少一个"前置条件通过但实际无解"的反例验证。报告里的实测数据若与你的结果不一致，明确指出。
4. **引用忠实性**：报告里的每一处引语都要能在 asr.md 中定位。发现改写、断章、把带犹豫的原话写成确定事实的，逐条列出。
5. **面试官档位**：只能是 A/B/C/D，禁止 A-/B+/B- 等子档。检查档位与 interviewer-rubric 的定义是否匹配。
6. **对外交付物纯净度**：evaluation.md 不得含内部术语（取样单元/压分项/前置门）、断链文件引用（coding-analysis.md 等）、改判过程、规则援引。

## 输出格式（严格遵守）
\`\`\`
# 结论摘要
（≤6 行：综合分是否成立/正确分数是多少；最严重的问题是什么）

# 高危 findings（会导致错误结论，必须改）
（每条：位置 → 为什么错 → 正确应该是什么。没有就写"无"）

# 中危 findings（会导致判分漂移或措辞不当）

# 低危 findings（可读性、措辞、格式）

# 我复算的六维与综合分
（表格 + 依据的决策表第几条）
\`\`\`

不要客套，不要为了平衡而编造优点。没有省略号，不要截断。
EOF

echo "[$(date '+%H:%M:%S')] 启动多路 review: $CAND/$ROUND"
echo "  模型: $MODELS"

pids=()
labels=()
IFS=',' read -ra MODEL_ARR <<< "$MODELS"
for m in "${MODEL_ARR[@]}"; do
  m="$(echo "$m" | tr -d ' ')"
  [[ -z "$m" ]] && continue
  for pass in 1 2; do
    focus_var="PASS${pass}_FOCUS"
    out="$REVIEW_DIR/${m}-pass${pass}.md"
    log="$REVIEW_DIR/.${m}-pass${pass}.log"
    # 注意：不要用 setsid——macOS 没有这个命令（实测 command not found），
    # 用它会导致整批 review 静默不启动。nohup + </dev/null 已足够脱离终端。
    # --sandbox workspace-write 必须显式给：codex exec 默认 read-only 沙箱，
    # 6 路会各自跑完整套分析却在最后一步写文件时被拒，产出 0/6（实测 2026-09-08）。
    # -C 把工作根设为候选人目录（写 review/ 用），--add-dir 放开只读的 skill 规则目录。
    nohup "$CODEX" exec --model "$m" --skip-git-repo-check \
      --sandbox workspace-write -C "$TARGET" --add-dir "$SKILL_DIR" \
      "读取 ${BRIEF} 作为任务说明，按其中要求做严格 review，完整结果写入 ${out}。${!focus_var} 材料较多，请优先保证写出文件——读到足够判断即可动笔。写完回复 DONE。" \
      > "$log" 2>&1 < /dev/null &
    pids+=("$!"); labels+=("${m}-pass${pass}")
    echo "  → ${m}-pass${pass} (pid $!)"
    sleep 1
  done
done

# 超时给 40 分钟：pass1（事实核查路）要逐条核对引用与完整转写，实测 41KB 转写
# 的场次 25 分钟不够（一路卡在读材料阶段被杀，白跑）。40 分钟是实测能跑完的下限。
echo "[$(date '+%H:%M:%S')] 等待 ${#pids[@]} 路完成（最长 40 分钟）..."
deadline=$(( $(date +%s) + 2400 ))
# 「多数完成」宽限：够数之后不必为最后一两路干等到硬超时。
# 达到 majority 后再给 6 分钟，慢的那路能赶上就赶上，赶不上就按未产出计。
majority=$(( (${#labels[@]} + 1) / 2 + 1 ))   # 6 路 → 4 路
grace_until=0
while true; do
  done_n=0
  for l in "${labels[@]}"; do [[ -s "$REVIEW_DIR/${l}.md" ]] && done_n=$((done_n+1)); done
  [[ $done_n -ge ${#labels[@]} ]] && { echo "[$(date '+%H:%M:%S')] 全部产出"; break; }

  if [[ $done_n -ge $majority && $grace_until -eq 0 ]]; then
    grace_until=$(( $(date +%s) + 360 ))
    echo "[$(date '+%H:%M:%S')] 已达 $done_n/${#labels[@]}（多数），再宽限 6 分钟等剩余"
  fi
  if [[ $grace_until -ne 0 && $(date +%s) -gt $grace_until ]]; then
    echo "[$(date '+%H:%M:%S')] 宽限结束，产出 $done_n/${#labels[@]}，收尾"
    for p in "${pids[@]}"; do kill -TERM "-$p" 2>/dev/null; kill -TERM "$p" 2>/dev/null; done
    break
  fi

  alive=0
  for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=$((alive+1)); done
  if [[ $alive -eq 0 ]]; then echo "[$(date '+%H:%M:%S')] 进程均退出，产出 $done_n/${#labels[@]}"; break; fi
  if [[ $(date +%s) -gt $deadline ]]; then
    echo "[$(date '+%H:%M:%S')] 硬超时，杀残留进程；产出 $done_n/${#labels[@]}"
    for p in "${pids[@]}"; do kill -TERM "-$p" 2>/dev/null; kill -TERM "$p" 2>/dev/null; done
    break
  fi
  sleep 20
done

# 汇总
SUMMARY="$REVIEW_DIR/SUMMARY.md"
{
  echo "# 多路 review 汇总 · $CAND/$ROUND"
  echo
  echo "生成时间见文件 mtime。模型: $MODELS"
  echo
  echo "## 各路结论摘要"
  echo
  for l in "${labels[@]}"; do
    f="$REVIEW_DIR/${l}.md"
    echo "### $l"
    if [[ -s "$f" ]]; then
      sed -n '/^# 结论摘要/,/^# /p' "$f" | sed '1d;$d' | head -12
    else
      echo "（未产出）"
    fi
    echo
  done
  echo "## 高危 findings 合并"
  echo
  for l in "${labels[@]}"; do
    f="$REVIEW_DIR/${l}.md"
    [[ -s "$f" ]] || continue
    hi="$(sed -n '/^# 高危/,/^# 中危/p' "$f" | sed '1d;$d')"
    if [[ -n "$(echo "$hi" | tr -d '[:space:]')" && "$(echo "$hi" | tr -d '[:space:]')" != "无" ]]; then
      echo "**[$l]**"; echo "$hi"; echo
    fi
  done
} > "$SUMMARY"

hi_count=0
ok_count=0
fail_labels=""
for l in "${labels[@]}"; do
  f="$REVIEW_DIR/${l}.md"
  if [[ ! -s "$f" ]]; then
    # 区分"没跑成"和"跑了说没问题"——网关过载/超时不能算通过（实测遇到
    # "stream disconnected before completion: Our servers are currently overloaded"）
    fail_labels+="$l "
    continue
  fi
  ok_count=$((ok_count+1))
  body="$(sed -n '/^# 高危/,/^# 中危/p' "$f" | sed '1d;$d' | tr -d '[:space:]')"
  [[ -n "$body" && "$body" != "无" ]] && hi_count=$((hi_count+1))
done

echo "[$(date '+%H:%M:%S')] 汇总: $SUMMARY"
echo "  成功 $ok_count/${#labels[@]} 路；其中 $hi_count 路报高危"
[[ -n "$fail_labels" ]] && echo "  未产出: $fail_labels"

if [[ $hi_count -gt 0 ]]; then
  echo "⚠️  有高危 findings —— 需人工确认并改判后才可对外提交"
  exit 1
fi
# 至少要有 2 路成功才认可"无高危"这个结论，否则样本太少不足以背书
if [[ $ok_count -lt 2 ]]; then
  echo "⚠️  仅 $ok_count 路成功，样本不足以支撑'无高危'结论，按需人工确认"
  exit 1
fi
echo "✅ 无高危 findings（$ok_count 路一致）"
exit 0
