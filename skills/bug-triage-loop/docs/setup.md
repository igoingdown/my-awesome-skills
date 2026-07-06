# docs/setup.md

## 首次启动

### 1. 前置

```bash
# Claude Code
claude --version

# 全局 lark-* skill 已安装(lark-event / lark-im / lark-contact / lark-shared)
ls ~/.claude/skills/ | grep -E "(lark-event|lark-im|lark-contact)"
```

如果 lark-cli 尚未登录或 skill 不认识,参考 `~/.claude/skills/lark-shared/SKILL.md`。**本手册不重复讲 lark 环境准备**。

### 2. 安装本 skill

```bash
# 从 my-awesome-skills 仓拷进 Claude Code skill 目录
cp -R skills/bug-triage-loop ~/.claude/skills/
# 或用仓根目录的 sync.sh
./sync.sh
```

### 3. 填 config.md

```bash
cd ~/.claude/skills/bug-triage-loop   # 或你自己 clone 的路径

# 用编辑器把 docs/config.md 里 3 个 FILL_ME 占位符替换成你的真实值
$EDITOR docs/config.md

# 校验
grep -E "^(bug_chat_id|my_open_id|github_root):" docs/config.md | grep -v FILL_ME | wc -l
# 期望 3
```

如何拿 `bug_chat_id` / `my_open_id`,`config.md` 里已经说明,或直接问 Claude Code(它会用 lark-contact / lark-im skill 查)。

### 4. 配置候选仓映射表

编辑 `docs/config.md` 里 §"涉及的仓库",替换示例行为你项目的真实仓库。**这个表决定 Step 7 会开哪些仓的 worktree**。若你项目全部在一个 repo 里,只留一行即可。

### 5. 手动跑一轮

```
/bug-triage-loop
```

首次会:

- 用 lark-im skill 拉最近 N 天(默认 7)群历史
- 判定 + 语义去重 + 挑一条最新的
- 按 module 扫候选仓 + 定位
- 生成 review markdown
- 静默时段外发一条飞书私聊

**预计耗时 5-15 分钟**。

### 6. Review 第一条

对话里回复:

- `approve` = 认可,归档,推进下一条
- `reject: <理由>` = 分析有误
- `defer` = 稍后再看,不推进

### 7. 挂 /loop

review 稳定跑通几条后:

```
/loop 5m /bug-triage-loop
```

## MCP 前置(可选,精度提升)

skill 的 Step 7 定位阶段可选依赖以下 MCP。**没挂也能跑**,但相关证据源会标 `tool_failure`,verdict 上限降到 needs-more-signal / likely。

| MCP | 用途 |
|---|---|
| bytebase | 查 MySQL/PG 数据 |
| aliyun-sls | 查 SLS 日志 |
| signoz / logfire | 查服务 trace / 指标 |

**踩坑**:MCP 挂了之后**当前对话不会立刻生效**,需要**完全重启 Claude Code**(不是重启对话,是关掉进程再开)才能挂到新 session。

```bash
# 检查已挂 MCP
claude mcp list

# 若缺, 按你项目的 MCP 域名添加,例如:
claude mcp add --transport http bytebase https://YOUR_BYTEBASE_DOMAIN/mcp
# aliyun-sls 通常走 metamcp token, 参考你项目的 oncall/debug 类 skill

# 完全重启 Claude Code
```

## Worktree 隔离约定

**约定**:每处理一条 bug,定位阶段(Step 7)在候选仓的独立 git worktree 里跑,避免污染主分支/主 checkout。

- Worktree 存放位置:`<github_root>/bug-triage-worktrees/<message_id_short>/<repo_name>/`
- **只读**:不允许 checkout 新分支、不允许 commit、不允许 push
- 用完自动清理:review 完成后由 skill 或用户手动清

Worktree 用法(skill 内部自动做,列出来是让你排查故障时能对上):

```bash
# 定位阶段前
git -C <github_root>/<repo> worktree add --detach \
  <github_root>/bug-triage-worktrees/<short>/<repo> origin/<branch>

# 定位完成
git -C <github_root>/<repo> worktree remove \
  <github_root>/bug-triage-worktrees/<short>/<repo> --force
```

好处:

- 不同 bug 排查互不干扰
- 主 checkout 保持在你的 feature 分支上,不会被定位过程 touched
- worktree 是文件系统层面的隔离,skill 出错不会导致主 checkout 状态异常

## Dynamic Workflow 加速定位(可选)

定位阶段(Step 7)默认串行。**若证据源估算 >= `workflow_min_evidence_sources`(默认 3)**,skill 自动切换到 Dynamic Workflow,并发跑多路 agent(SLS / DB / memory / 代码)。

## 日常操作

### 我关电脑一天后怎么继续?

```bash
cd ~/.claude/skills/bug-triage-loop
claude
# 对话里
/loop 5m /bug-triage-loop
```

未处理消息按 message_id 去重,不受关机影响。

### 查历史 review

```bash
# 找某条 bug 的完整分析
grep -F "<message_id>" state/review-queue.jsonl | jq .

# 最近 10 条 review
tail -10 state/review-queue.jsonl | jq -r '{message_id, title, verdict, confidence, severity, status}'

# verdict / severity 分布
jq -r '"\(.verdict) \(.severity // "-")"' state/processed.jsonl | sort | uniq -c
```

### 迭代 prompt

改 `prompts/triage.md` 或 `prompts/rubric.md`,下一轮 loop 立即用新版本,**不用重启**。

### state/ 提交策略

`state/` 里含真实事故内容(uid / open_id / 内部人名 / 生产交易键等),**不要 push 到公开仓**。若要多机同步,push 到私有仓。

**不要**手动编辑 state/ 里的文件。所有变更走 skill 或 review 回复。

## 故障排查

### /bug-triage-loop 报错 "config.md 缺 bug_chat_id"

→ 填 config.md 里对应字段

### lark-im 拉群历史失败 / lark-cli 报权限

→ 参考 `~/.claude/skills/lark-shared/SKILL.md`,处理 auth 问题;不在本手册重复讲

### MCP 反复 Stream closed

skill 内置降级(见 SKILL.md §错误处理):

- Read/Write 断 → 用 Bash + heredoc / python3 -c 落文件
- bytebase query_database 断 → 换 call_api 显式全路径
- aliyun-sls 断 → 尝试其他 region + 换 query 语法
- 3 次仍失败 → 主动降级:该证据源标 tool_failure

### review-queue.jsonl 尾部 status 一直 pending_review

- 对话里明确回复 `approve` / `reject:` / `defer`
- 或手动:

  ```bash
  python3 -c "
  import json
  lines = open('state/review-queue.jsonl').readlines()
  last = json.loads(lines[-1]); last['status'] = 'reviewed_approved'
  lines[-1] = json.dumps(last, ensure_ascii=False) + '\n'
  open('state/review-queue.jsonl', 'w').writelines(lines)
  "
  ```

### /loop 停不下来

- `/loop stop`
- 无效 → `Ctrl+C` → `/loop stop`
- 最后 → 关闭 Claude Code 进程

### worktree 残留

```bash
# 列出所有 worktree
git -C <github_root>/<repo> worktree list

# 清 bug-triage 池
find <github_root>/bug-triage-worktrees -mindepth 1 -maxdepth 2 -type d | while read wt; do
  parent=$(git -C "$wt" rev-parse --show-superproject-working-tree 2>/dev/null || true)
  git -C "$wt" worktree remove . --force 2>/dev/null || true
done
rm -rf <github_root>/bug-triage-worktrees
```

## 下一步(v2 扩展)

- 反馈按钮:飞书 Interactive Card 让你在飞书里直接 approve
- 对抗验证 subagent:自动反命题
- 证据集持久化:每条真调 SLS/DB 的原始返回落盘

**这些都不在 MVP 范围**。等 MVP 跑几周稳定,再决定是否升级。
