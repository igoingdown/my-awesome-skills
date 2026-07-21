# CodeX 启动命令详解

## 命令

```bash
codex --search exec \
  -c model_reasoning_effort="xhigh" \
  --cd "<repo 根目录>" \
  --skip-git-repo-check \
  --dangerously-bypass-approvals-and-sandbox \
  - < <工作目录>/codex-review-prompt.md
```

> ⚠️ **`--search` 必须放在顶层（`codex --search exec ...`），不能放在 `exec` 之后。** 在 codex 0.133 实测，`codex exec --search` 会报 `error: unexpected argument '--search' found`。这是一个真实的版本行为，写错位置整条命令直接失败。

> ⚠️ **必须加 `--dangerously-bypass-approvals-and-sandbox`。** 不加（即默认 read-only 沙箱）会导致 CodeX 读不到工作目录外的文件、也无法临时写记录文件（如中间笔记），评审会因权限受限而残缺。本场景是受控本地评审，绕过沙箱安全可接受——且评审指令已明令禁止改源码，是逻辑层面的双保险。该 flag 放在 `exec` 之后（子命令选项）。

用工具的 `run_in_background` 起这条命令；记下返回的进程/任务标识，供轮询。

## 逐项要点

- **`-c model_reasoning_effort="xhigh"`** —— 即 **Thinking level = Max**。可选值 `minimal|low|medium|high|xhigh`，对抗式深评固定用 `xhigh`。
- **`--search`（顶层 flag）** —— 启用 CodeX 原生 `web_search` 工具，让它能联网取 SOP 出处。**这是"SOP 必带来源"的前提，不加这条则取证要求落空。** 注意必须是 `codex --search exec`，放到子命令后会报错。
- **`-` + stdin 重定向** —— 把 prompt 文件喂给 CodeX（也可作为 `[PROMPT]` 参数，但 stdin 更稳，长文档不撞命令行长度限制）。
- **`--cd <repo 根>`** —— 让 CodeX 在仓库根作业，才能按 file:line 打开文件核对。
- **模型** —— 默认走 `~/.codex/config.toml`（本机 `gpt-5.5`）；要覆盖加 `-m <model>`。
- **`--dangerously-bypass-approvals-and-sandbox`（`exec` 子命令选项）** —— 跳过所有审批提示并关闭沙箱。**这是评审能读全仓库文件、能临时写记录文件的前提**；缺它则默认 read-only 沙箱会卡住读取与写入，评审残缺。仅用于受控本地评审，禁改源码由评审指令在逻辑层兜底。
- **沙箱** —— 用上面的 bypass flag 放开读写（替代默认 read-only）。评审仍只读不改源码：这一约束靠指令明令保证，而非靠沙箱限制。

## 健康监控（替代被动轮询）

xhigh 深评常跑 30-60+ 分钟。**不要只等退出通知、更不要 `sleep` 空等到底**——CodeX 中途可能死掉或异常，用户会一直干等。启动后立刻用 `run_in_background` 挂一个监控循环，周期采样，异常提前退出上报：

```bash
# 监控循环：每 60s 采样；正常退出=codex 结束；提前退出=异常，输出原因
CODEX_PID=<codex 真实进程 PID>   # 注意 setsid 包装时要取 codex 本体，不是 wrapper bash
LOG=<工作目录>/codex-run.log
STALL_LIMIT=300   # 日志停滞容忍秒数
last_size=0; stall=0
while kill -0 "$CODEX_PID" 2>/dev/null; do
  size=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  if [ "$size" -eq "$last_size" ]; then stall=$((stall+60)); else stall=0; fi
  last_size=$size
  [ "$stall" -ge "$STALL_LIMIT" ] && { echo "ANOMALY: log stalled ${stall}s (size=$size)"; exit 2; }
  # 递归检测：codex 不该再起 codex（实测发生过，见下）
  child=$(pgrep -P "$CODEX_PID" -f codex 2>/dev/null | head -1)
  [ -n "$child" ] && { echo "ANOMALY: recursive codex child pid=$child"; exit 3; }
  sleep 60
done
echo "codex exited normally"; ls -la <工作目录>/codex-review.md 2>/dev/null
```

判定与处置：

- **正常退出（exit 0 且 review 文件在）** → 进入二次评估。注意 `codex-review.md` 落盘 ≠ 结束：实测 CodeX 写完报告后还会继续活动几分钟，**以进程退出为准**再读最终版。
- **日志停滞**（进程活着但 log 长时间不长）→ 多为网络重试空转或模型卡死。tail 日志把最近活动报给用户，附进程清单（PID/启动时间/完整命令行），**kill 须用户确认**（见 SKILL.md 红线）。
- **递归子 codex** → CodeX 在 bypass-sandbox 下可能自己再调 `codex` 委托评审（2026-07-21 实测：外层 codex 两次把评审转包给子 codex，多烧一倍时间与 token）。预防靠 prompt 里的反递归条款（见 `review-prompt-template.md` 开头 EXECUTION RULE）；监控发现时报给用户处置，不自行 kill。
- **进程死了但没有 review 文件** → 检查 log 尾部（API 报错/上下文溢出/命令行错误），修正后重跑；重跑前按 SKILL.md 第 3 条清点账本。
- **监控本身超时**（`run_in_background` 有 timeout 上限）→ 到点没结束就再挂一轮监控，同时在给用户的消息里报一次中间进度（跑了多久、日志多大、tail 在做什么），不要沉默。

用户中途询问进度时的标准答复素材：`ps -o etime= -p $CODEX_PID`（跑了多久）+ `stat -c '%y %s' $LOG`（日志最后活动）+ `tail -c 500 $LOG`（正在做什么）。
