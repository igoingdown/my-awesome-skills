# CodeX 启动命令详解

## 命令

```bash
codex --search exec \
  -c model_reasoning_effort="xhigh" \
  --cd "<repo 根目录>" \
  --skip-git-repo-check \
  - < <工作目录>/codex-review-prompt.md
```

> ⚠️ **`--search` 必须放在顶层（`codex --search exec ...`），不能放在 `exec` 之后。** 在 codex 0.133 实测，`codex exec --search` 会报 `error: unexpected argument '--search' found`。这是一个真实的版本行为，写错位置整条命令直接失败。

用工具的 `run_in_background` 起这条命令；记下返回的进程/任务标识，供轮询。

## 逐项要点

- **`-c model_reasoning_effort="xhigh"`** —— 即 **Thinking level = Max**。可选值 `minimal|low|medium|high|xhigh`，对抗式深评固定用 `xhigh`。
- **`--search`（顶层 flag）** —— 启用 CodeX 原生 `web_search` 工具，让它能联网取 SOP 出处。**这是"SOP 必带来源"的前提，不加这条则取证要求落空。** 注意必须是 `codex --search exec`，放到子命令后会报错。
- **`-` + stdin 重定向** —— 把 prompt 文件喂给 CodeX（也可作为 `[PROMPT]` 参数，但 stdin 更稳，长文档不撞命令行长度限制）。
- **`--cd <repo 根>`** —— 让 CodeX 在仓库根作业，才能按 file:line 打开文件核对。
- **模型** —— 默认走 `~/.codex/config.toml`（本机 `gpt-5.5`）；要覆盖加 `-m <model>`。
- **沙箱** —— 默认 read-only 即可（评审只读不改）；指令里也已明令禁止改源码，双保险。

## 轮询

- **不要 `sleep` 空等**；`run_in_background` 起的进程会在结束时自动通知，到时再看产出。
- 主动确认进度：`ls -la <工作目录>/codex-review.md 2>/dev/null && wc -l <工作目录>/codex-review.md`，或看后台进程是否退出（exit 0 = 正常完成）。
