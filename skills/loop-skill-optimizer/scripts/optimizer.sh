#!/usr/bin/env bash
# 每日 skill 自进化流水线 + 合入后自动同步运行时 skill。
#
# 这是一个参考实现（去敏版）。它由 crontab 每 30 分钟调用（--cron），每次做两件事：
#   Phase A（合入同步）: 远端 main 有新提交 → fast-forward 本地 main → 跑 sync.sh 同步到
#     运行时 skill 目录 → 通知（=「同意合入 PR 后更新运行时 skill」）
#   Phase B（每日分析）: 过了当日调度点且当日未成功跑过 → 提取窗口内 session 的用户消息
#     （日常 24h；周日 14 天全量复扫）→ headless 分析：先把观察记入跨天主题账本，再按晋升
#     规则（出现 ≥3 次且跨 ≥2 天，或当日强纠偏破格）决定是否在临时 worktree 提交优化 →
#     敏感词硬闸门扫 diff/文案 → 通过才 push + 建 PR → 通知发 PR 链接。
#     服务器重启/宕机错过调度点由本机制自动补跑。
#
# 依赖（需自备/替换）：
#   - git、gh（GitHub CLI，已登录）
#   - claude（Claude Code CLI，headless 模式）
#   - $NOTIFY_CMD：把一条消息推到你的即时通知渠道的命令
#   - scripts/digest.py：把 session transcript 提取成用户消息清单
#   - 仓库根目录的 sync.sh：把 skills/ 同步到运行时目录
#
# 用法: optimizer.sh [--cron|--dry-run|--force]
#   --cron     crontab 入口：按调度点判断是否该跑（默认）
#   --dry-run  立即以今天为目标跑一次完整流程，但不 push、不建 PR、不写完成戳
#   --force    立即以今天为目标真跑一次（忽略完成戳）

set -uo pipefail

# ---- 加载配置（把真实值放在仓库之外的 config，见 config.example.sh）----
CONFIG="${LOOP_SKILL_OPTIMIZER_CONFIG:-$HOME/.config/loop-skill-optimizer.sh}"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && source "$CONFIG"

REPO="${SKILL_REPO_DIR:?请在 config 里设置 SKILL_REPO_DIR}"
REPO_SLUG="${SKILL_REPO_SLUG:?请在 config 里设置 SKILL_REPO_SLUG}"
STATE_DIR="${OPTIMIZER_STATE_DIR:-$HOME/.local/var/skill-optimizer}"
SCHED_HOUR="${OPTIMIZER_SCHED_HOUR:-21}"
NOTIFY_CMD="${NOTIFY_CMD:-}"
DENYLIST="$STATE_DIR/denylist.txt"
LOG="$STATE_DIR/optimizer.log"
MAX_ATTEMPTS=3
CLAUDE_TIMEOUT=3600

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIGEST_PY="$SCRIPT_DIR/digest.py"

MODE="${1:---cron}"

mkdir -p "$STATE_DIR/runs"
exec 9>"$STATE_DIR/.lock"
flock -n 9 || exit 0
exec >>"$LOG" 2>&1

log() { echo "[$(date -Is)] $*"; }

notify() {
  if [ -z "$NOTIFY_CMD" ]; then log "notify (no NOTIFY_CMD): $1"; return; fi
  "$NOTIFY_CMD" "$1" >/dev/null || log "notify FAILED: $1"
}

# 同一事件只告警一次（key 写入 alerted 文件）
notify_once() {
  local key="$1" msg="$2"
  grep -qxF "$key" "$STATE_DIR/alerted" 2>/dev/null && return 0
  notify "$msg" && echo "$key" >> "$STATE_DIR/alerted"
}

# ---------- Phase A: 合入后同步运行时 skill ----------

sync_phase() {
  git -C "$REPO" fetch origin main --quiet 2>/dev/null || { log "sync: git fetch failed (network?)"; return; }
  local remote_sha last_sha
  remote_sha=$(git -C "$REPO" rev-parse origin/main)
  last_sha=$(cat "$STATE_DIR/last-synced-sha" 2>/dev/null || true)
  [ "$remote_sha" = "$last_sha" ] && return

  log "sync: origin/main advanced ${last_sha:0:7} -> ${remote_sha:0:7}"
  # 门禁：本地必须在干净的 main 上，否则跳过（避免污染工作副本 / 丢失未提交改动）
  if [ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" != "main" ] || [ -n "$(git -C "$REPO" status --porcelain)" ]; then
    notify_once "dirty-$remote_sha" "⚠️ skill 自进化：远端 main 有新合入，但本地仓库不在干净的 main 上，已跳过运行时同步。处理干净后下次 tick 会自动重试。"
    return
  fi
  if ! git -C "$REPO" merge --ff-only origin/main --quiet; then
    notify_once "fffail-$remote_sha" "⚠️ skill 自进化：本地 main 无法 fast-forward 到远端，已跳过运行时同步，请人工处理。"
    return
  fi

  local changed=""
  if [ -n "$last_sha" ]; then
    changed=$(git -C "$REPO" diff --name-only "$last_sha" "$remote_sha" -- skills/ 2>/dev/null \
      | cut -d/ -f2 | sort -u | sed ':a;N;s/\n/、/;ta')
  fi
  if [ -z "$last_sha" ] || [ -n "$changed" ]; then
    if "$REPO/sync.sh" >/dev/null; then
      echo "$remote_sha" > "$STATE_DIR/last-synced-sha"
      log "sync: done, changed skills: ${changed:-<all>}"
      notify "✅ skill 合入已生效：${changed:-全量} 已同步到运行时 skill 目录。新会话重启后生效。"
    else
      notify_once "syncfail-$remote_sha" "❌ skill 自进化：sync.sh 执行失败，运行时 skill 未更新。请查看日志。"
    fi
  else
    # main 前进了但没动 skills/（如 README），只记账不打扰
    echo "$remote_sha" > "$STATE_DIR/last-synced-sha"
    log "sync: main advanced without skills/ change, recorded sha"
  fi
}

# ---------- Phase B: 每日分析 + 提 PR ----------

due_date() {
  if [ "$((10#$(date +%H)))" -ge "$SCHED_HOUR" ]; then date +%F; else date -d yesterday +%F; fi
}

finish_day() { echo "$1" > "$STATE_DIR/last-run-date"; }

cleanup_wt() {
  local wt="$1" branch="$2"
  git -C "$REPO" worktree remove --force "$wt" 2>/dev/null || true
  git -C "$REPO" branch -D "$branch" 2>/dev/null || true
}

fail_run() {
  local due="$1" run_dir="$2" msg="$3"
  log "analysis FAIL ($due): $msg"
  local attempts; attempts=$(cat "$run_dir/attempts" 2>/dev/null || echo 1)
  if [ "$MODE" != "--cron" ]; then
    notify "❌ skill 自进化（$due，手动 $MODE）失败：$msg。详见 $run_dir/"
  elif [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
    notify "❌ skill 自进化（$due）连续 $MAX_ATTEMPTS 次失败，已停止自动重试：$msg。修好后可手动跑 optimizer.sh --force"
    finish_day "$due"
  else
    log "will retry on next tick (attempt $attempts/$MAX_ATTEMPTS)"
  fi
}

run_analysis() {
  local due="$1"
  local run_dir="$STATE_DIR/runs/$due"
  mkdir -p "$run_dir"

  local attempts=0
  if [ "$MODE" = "--cron" ]; then
    attempts=$(cat "$run_dir/attempts" 2>/dev/null || echo 0)
    [ "$attempts" -ge "$MAX_ATTEMPTS" ] && return
    echo $((attempts + 1)) > "$run_dir/attempts"
  fi
  log "=== analysis for $due (mode=$MODE attempt=$((attempts + 1))) ==="

  local start end digest="$run_dir/digest.txt"
  # 周日做 14 天全量复扫，补日常 24h 窗口漏掉的跨天模式；其余按日窗口
  if [ "$(date -d "$due" +%u)" = "7" ]; then
    start=$(date -d "$due - 13 day" +%F)
    log "sunday full rescan: window $start ~ $due"
  else
    start=$(date -d "$due - 1 day" +%F)
  fi
  end=$(date -d "$due + 1 day" +%F)
  if ! python3 "$DIGEST_PY" "$start" "$end" > "$digest" 2>"$run_dir/digest.err"; then
    fail_run "$due" "$run_dir" "digest 提取失败"
    return
  fi
  if [ ! -s "$digest" ]; then
    log "empty digest, skip"
    notify "😴 skill 自进化（$due）：窗口内没有任何 session，跳过。"
    finish_day "$due"
    return
  fi

  local branch="skill-opt/$due" wt="/tmp/skill-opt-wt-$due"
  cleanup_wt "$wt" "$branch"
  if ! git -C "$REPO" worktree add -b "$branch" "$wt" origin/main --quiet; then
    fail_run "$due" "$run_dir" "创建 worktree 失败"
    return
  fi
  rm -f "$run_dir"/{decision,reason,pr-title,pr-body,notify-summary,diff.txt,denylist-hits.txt}

  local skills_list
  skills_list=$(ls "$REPO/skills" | sed ':a;N;s/\n/、/;ta')

  local themes_file="$STATE_DIR/themes.md"
  [ -f "$themes_file" ] || printf '# 用户反复强调内容 · 主题账本\n\n(空账本，由 skill 自进化流水线维护)\n' > "$themes_file"

  local prompt
  prompt=$(cat <<EOF
你是「每日 skill 优化」自动化流水线中的分析与编码步骤，运行在无人值守的 headless 模式。当前工作目录是 skill 仓库的一个临时 worktree（分支 $branch，基于 origin/main）。这个仓库在 GitHub 上是【公开开源】的。

【输入】
- 文件 $digest 是时间窗口内本机所有 Claude Code session 的用户消息清单（日常为最近 24 小时；周日为最近 14 天全量复扫，用于补跨天模式）。按 session 分组，每组头部有原始 transcript 的绝对路径，需要更多上下文时可以直接 Read 该文件核实（transcript 很大，用 offset/limit 或 Grep 定位）。
- 文件 $themes_file 是跨天累积的【主题账本】：记录用户反复强调的工作方式主题、出现次数、状态。这是你判断"值不值得沉淀"的核心依据。
- 本仓库现有 skill（skills/ 目录）：$skills_list

【任务：两阶段】

阶段一·记账（每次必做，与是否提 PR 无关）：
1. 通读清单，找出用户对 Claude 工作方式的批判、打断纠偏、重复强调的要求、踩坑复盘、明确的流程偏好。跳过自动化任务自身产生的模板化会话（周报生成、每日 skill 优化、余额查询、自动探针等机器开场白）。
2. 把每条观察合并进主题账本 $themes_file：命中已有主题 → 该主题计数 +1、追加日期与一句话原话线索；是新主题 → 新建条目（状态=观察中，计数=1）。直接编辑该文件，保持其现有结构。账本在 worktree 之外，允许写。

阶段二·晋升判定（决定提不提 PR）：
3. 去重：先运行「gh pr list --repo $REPO_SLUG --state all --limit 30」和「git log --oneline -30」，已有 PR 或已合入内容覆盖的观点不要重复提；对应主题在账本里标状态"已提PR"或"已合入"。用户在 PR 里关闭/否决过的，标"用户已否决"，以后不再提。
4. 晋升规则：账本中状态为"观察中"且【出现次数 ≥3 且跨 ≥2 个不同日期】的主题，晋升为本次 PR 候选。当日一次性的强纠偏（如明确说"写进记忆/这是纪律/以后都要"）可破格晋升，但要在 PR 描述里注明破格理由。不够格的只记账，不提 PR。
5. 落点选择：晋升主题优先并入最相关的已有 skill（先读原文件再动手，遵循其结构与风格，改动小而准）；确实无家可归的允许新建 skill（一次最多建一个，PR 描述里说明为何不并入现有 skill）。
6. 没有晋升主题：把单词 NOPR 写入 $run_dir/decision，把一两句中文理由写入 $run_dir/reason（注明账本更新了几个主题），结束。
7. 有晋升主题：在 worktree 修改对应 skill 文件，git add 后 commit（可多个 commit，中文消息、feat/fix 前缀，风格参考 git log）。提 PR 的主题在账本里标"已提PR"。最后写四个文件：
   - $run_dir/decision：单词 PR
   - $run_dir/pr-title：一行 PR 标题
   - $run_dir/pr-body：PR 描述（markdown，逐条列出：动机(含主题出现次数与跨度) → 改动内容）
   - $run_dir/notify-summary：发到你手机的中文摘要，每个优化点一行，总共不超过 6 行

【脱敏红线——仓库公开，以下内容绝对不能出现在 commit 消息、代码/文档改动、PR 标题/描述、摘要的任何位置】
- 公司名、内部项目/服务/产品名、代号、同事姓名、组织信息
- 内部域名、URL、IP、端口、服务器名、路径里的用户名、数据库/实例/群名
- 任何 token、密钥、app_id、open_id、chat_id 等凭证或标识
- 生产日志原文、线上事故可识别细节、用户数据
做法：把具体案例抽象成通用场景（写「某内部服务的告警排查」而不是真实服务名）。个别存量文档历史上可能已含内部服务名：不要在新增行里再引入这些名字，包含内部名的旧行能不动就不动，新增内容一律用通用称谓。完成后必须自查：运行「git diff origin/main...HEAD」逐行检查，同时检查四个输出文件。外层脚本还有敏感词硬闸门，命中会整体拦截并惊动人工，务必一次做干净。
注意：主题账本 $themes_file 里可以保留原话线索（它不进仓库），但**从账本到 skill 文件的内容必须完成脱敏抽象**，绝不把账本原话直接复制进仓库文件。

【禁止事项】
- 禁止 git push、禁止创建 PR、禁止切换或修改 main——推送与建 PR 由外层脚本在敏感词扫描通过后完成。
- 禁止改动 worktree 之外的任何文件（$run_dir 下的输出文件与主题账本 $themes_file 除外）。
- 禁止把 $digest 或 transcript 内容原样复制进仓库文件。
EOF
)

  log "invoking headless claude..."
  ( cd "$wt" && timeout "$CLAUDE_TIMEOUT" claude -p "$prompt" \
      --allowedTools "Bash,Read,Write,Edit,Grep,Glob" \
      --disallowedTools "Bash(git push:*),Bash(gh pr create:*),Bash(gh pr merge:*),Bash(gh repo:*)" \
      --max-turns 150 </dev/null > "$run_dir/claude-output.log" 2>&1 )
  local rc=$?
  log "claude exited rc=$rc"

  local decision
  decision=$(cat "$run_dir/decision" 2>/dev/null || echo "")

  if [ "$decision" = "NOPR" ]; then
    local reason; reason=$(head -c 300 "$run_dir/reason" 2>/dev/null || echo "")
    notify "😴 skill 自进化（$due）：未发现值得迭代的内容。${reason}"
    finish_day "$due"
    cleanup_wt "$wt" "$branch"
    return
  fi
  if [ "$decision" != "PR" ]; then
    fail_run "$due" "$run_dir" "headless claude 未产出有效结论（rc=$rc, decision='${decision}'）"
    cleanup_wt "$wt" "$branch"
    return
  fi
  if [ -z "$(git -C "$wt" log origin/main..HEAD --oneline 2>/dev/null)" ]; then
    fail_run "$due" "$run_dir" "decision=PR 但 worktree 没有任何 commit"
    cleanup_wt "$wt" "$branch"
    return
  fi
  for f in pr-title pr-body notify-summary; do
    if [ ! -s "$run_dir/$f" ]; then
      fail_run "$due" "$run_dir" "缺少输出文件 $f"
      cleanup_wt "$wt" "$branch"
      return
    fi
  done

  # ---- 敏感词硬闸门：只扫新增行 + commit 消息 + PR 文案，命中即拦截 ----
  # 存量豁免：仓库是公开的，部分文档在 main 上本就含某些词；
  #   - diff 新增行：命中词在该文件的 origin/main 版本里已存在 → 不算新增暴露，放行
  #   - commit 消息/PR 文案：命中词在 origin/main 任意文件已存在 → 放行
  #   - 该文件/仓库从未出现过的词（密钥、IP、ID 等永远如此）→ 拦截
  git -C "$wt" log -p origin/main..HEAD > "$run_dir/diff.txt"
  git -C "$wt" diff -U0 origin/main..HEAD | awk '
    /^\+\+\+ /{ if ($2 == "/dev/null") f = ""; else { f = $2; sub(/^b\//, "", f) } next }
    /^\+/ && f != "" { print f "\t" substr($0, 2) }
  ' > "$run_dir/added-lines.tsv"
  git -C "$wt" log --format=%B origin/main..HEAD > "$run_dir/commit-msgs.txt"

  : > "$run_dir/denylist-hits.txt"
  if [ -f "$DENYLIST" ]; then
    local p matches path line
    while IFS= read -r p; do
      # diff 新增行（文件级存量豁免）
      matches=$(grep -iE -e "$p" "$run_dir/added-lines.tsv" 2>/dev/null || true)
      if [ -n "$matches" ]; then
        while IFS=$'\t' read -r path line; do
          [ -n "$path" ] || continue
          if git -C "$wt" show "origin/main:$path" 2>/dev/null | grep -qiE -e "$p"; then
            continue
          fi
          printf 'DIFF %s | %s | pattern: %s\n' "$path" "$line" "$p" >> "$run_dir/denylist-hits.txt"
        done <<< "$matches"
      fi
      # commit 消息 + PR 文案（仓库级存量豁免）
      if ! git -C "$wt" grep -qiE -e "$p" origin/main -- 2>/dev/null; then
        grep -hiE -e "$p" "$run_dir/commit-msgs.txt" "$run_dir/pr-title" "$run_dir/pr-body" "$run_dir/notify-summary" 2>/dev/null \
          | while IFS= read -r line; do
              printf 'COPY %s | pattern: %s\n' "$line" "$p" >> "$run_dir/denylist-hits.txt"
            done
      fi
    done < <(grep -v '^\s*#' "$DENYLIST" | grep -v '^\s*$')
  fi

  if [ -s "$run_dir/denylist-hits.txt" ]; then
    log "DENYLIST HIT: $(wc -l < "$run_dir/denylist-hits.txt") lines, push blocked"
    local hits_excerpt; hits_excerpt=$(head -c 800 "$run_dir/denylist-hits.txt")
    if [ "$MODE" = "--dry-run" ]; then
      notify "🧪【DRY-RUN】skill 自进化（$due）：流程跑通，但产出命中敏感词拦截（正式运行时会阻止推送并转人工）。命中：
$hits_excerpt"
    else
      notify "🛑 skill 自进化（$due）：产出的 PR 内容命中敏感词拦截，已阻止推送（仓库是公开的）。改动保留在 worktree $wt（分支 $branch），人工脱敏后可手动 push + 提 PR。命中：
$hits_excerpt"
      finish_day "$due"
    fi
    return
  fi
  log "denylist scan clean"

  if [ "$MODE" = "--dry-run" ]; then
    notify "🧪【DRY-RUN】skill 自进化（$due）全链路验证通过：已在本地生成优化 commit 并通过敏感词扫描，未推送。摘要：
$(cat "$run_dir/notify-summary")"
    log "dry-run success, cleaning up"
    cleanup_wt "$wt" "$branch"
    return
  fi

  if ! git -C "$wt" push -u origin "$branch" --quiet; then
    fail_run "$due" "$run_dir" "git push 失败"
    return
  fi
  local pr_url
  pr_url=$(cd "$wt" && gh pr create --repo "$REPO_SLUG" --base main --head "$branch" \
      --title "$(cat "$run_dir/pr-title")" --body-file "$run_dir/pr-body" 2>>"$LOG")
  if [ -z "$pr_url" ]; then
    fail_run "$due" "$run_dir" "gh pr create 失败（分支已推送 $branch）"
    return
  fi
  log "PR created: $pr_url"
  notify "📬 skill 自进化（$due）PR 已创建：
$pr_url

$(cat "$run_dir/notify-summary")

合入后 30 分钟内会自动同步到运行时 skill 目录。"
  finish_day "$due"
  cleanup_wt "$wt" "$branch"
}

analysis_phase() {
  local due stamp
  if [ "$MODE" = "--cron" ]; then
    due=$(due_date)
    stamp=$(cat "$STATE_DIR/last-run-date" 2>/dev/null || echo "")
    if [ -n "$stamp" ] && [ ! "$stamp" \< "$due" ]; then return; fi
  else
    due=$(date +%F)
  fi
  run_analysis "$due"
}

sync_phase
analysis_phase
