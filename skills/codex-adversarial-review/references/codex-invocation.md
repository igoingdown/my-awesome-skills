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

## 轮询

- **不要 `sleep` 空等**；`run_in_background` 起的进程会在结束时自动通知，到时再看产出。
- 主动确认进度：`ls -la <工作目录>/codex-review.md 2>/dev/null && wc -l <工作目录>/codex-review.md`，或看后台进程是否退出（exit 0 = 正常完成）。
