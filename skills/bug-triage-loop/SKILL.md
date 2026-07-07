---
name: bug-triage-loop
description: 拉飞书 Bug 群的新消息(含最近 N 天历史)按新→旧倒序、message_id 去重挑一条未处理的 bug 进行判定/定位/生成分析报告,展示给用户 review。严格串行:未 review 完的不推进。依赖 lark-event/lark-im/lark-contact 通用 skill + 项目侧 oncall/debug/code-analyze skill(或直接调 aliyun-sls/bytebase/signoz MCP)。当用户在 `/loop 5m /bug-triage-loop` 中调用时触发,或用户手动运行 `/bug-triage-loop` 时触发。
---

# bug-triage-loop skill

一次 /loop tick 的完整逻辑。**本 skill 只写状态文件 + 编排 prompt,所有实际动作走已有 skill**。

## 前置阅读(每次进入本 skill 都要读)

- 读 skill 目录下的 `docs/config.md` 拿到:`bug_chat_id`、`my_open_id`、`github_root`、`history_backfill_days`、`quiet_hours`、`workflow_min_evidence_sources`,以及 §"涉及的仓库"表
- 读 skill 目录下的 `prompts/triage.md` 拿判定 rubric
- 读 skill 目录下的 `prompts/rubric.md` 拿实锤 5 档 rubric
- 读 skill 目录下的 `prompts/report-format.md` 拿输出模板

## 依赖的 skill(**不重复实现**,统统 Skill 调用或引用命令)

| 场景 | 使用的 skill | 关键命令 |
|---|---|---|
| 拉群历史消息 | `lark-im` | `+chats-messages-get`(通过 Skill 工具唤起) |
| 发飞书私聊推送 | `lark-im` | `+messages-send` |
| 查 open_id / 姓名 | `lark-contact` | `+search-user` / `+get-user` |
| 查 SLS/DB/memory 等生产数据 | 项目侧 oncall / debug skill(如 `<project>-debug`),或直接用 aliyun-sls / bytebase / signoz MCP | 按各自 skill 或 MCP 文档 |
| 定位代码 | 项目侧 code-analyze skill(如 `bug-analyze`),或让主 loop 自己 Read + grep | — |
| lark-cli 权限/身份问题 | `lark-shared` | 参考它的 auth 章节 |

**注**:本 skill 不假设特定项目的 debug / analyze skill 命名。所有对飞书的动作都通过 `Skill` 工具调用对应 lark-* skill;所有生产数据动作优先走项目 oncall skill,若没有则直接调 MCP。lark skill 更新时,本 skill 无需改。

## 一次 loop 干什么(总览)

```
Step 0  加载配置 + 读 3 个 prompt 文件
Step 1  判断静默时段(22:00-08:00 Asia/Shanghai)→ is_quiet flag
Step 2  串行门禁:review-queue.jsonl 尾部是否 pending_review?若是 → 退出
Step 3  拿 processed.jsonl 已处理 message_id 集合 P
Step 4  用 lark-im skill 拉群历史(首次 60 天,后续从上次最新 processed_at)
Step 5  过滤:message_id ∉ P,时间新→旧倒序,取第一条
        └─ 无新消息 → 追加 state/loop.log,退出
Step 6  按 triage.md 判定 + 抽取(LLM 自己判,不用外部工具)
        ├─ not_bug   → 写 processed.jsonl,退出
        ├─ duplicate → 写 processed.jsonl,退出
        └─ real_bug  → 进入 Step 7
Step 7  开 worktree + 用项目侧 debug/analyze skill(或直接调 MCP)定位(可选 dynamic workflow 并发)
Step 8  按 rubric.md 打 5 档实锤 + score + 收集证据链
Step 9  按 report-format.md 生成 review markdown(含 <details> 折叠)
Step 10 写 state/review-queue.jsonl(status = pending_review)
Step 11 在对话中展示 review markdown
Step 12 若非静默 → 用 lark-im skill 给 my_open_id 发一条私聊
Step 13 清理 worktree + 退出。用户 review 后回复 approve/reject/defer,
        下一轮 loop 或用户主动触发时按 Step 2 门禁再进
```

## Step 详解

### Step 0:加载配置

用 `Read` 工具读 `docs/config.md`。用 grep/正则从 markdown 里抽 key: value。若缺 `bug_chat_id`/`my_open_id`/`github_root` 任一 → 提示用户,退出。

配置项:
- `bug_chat_id`(必)
- `my_open_id`(必)
- `github_root`(必,如 `/Users/<username>/github`)
- `history_backfill_days`(默认 60)
- `quiet_hours`(默认 22:00-08:00)
- `workflow_min_evidence_sources`(默认 3)

### Step 1:静默时段

用 `Bash`:`TZ=Asia/Shanghai date +"%H:%M"` 拿当前时间。
比较 `quiet_hours`(如 `22:00-08:00`)。**跨 0 点要处理**:22:00-08:00 意味着 22:00-23:59 或 00:00-08:00。

### Step 2:串行门禁

```bash
tail -n 1 state/review-queue.jsonl 2>/dev/null | jq -r '.status // "empty"'
```

- 输出 `pending_review` → 追加一行 `state/loop.log`:"等 review",退出。**不做任何其他动作**。
- 输出 `reviewed_approved` / `reviewed_rejected` / `deferred` / `empty` → 继续。

**注意 deferred**:defer 后 review-queue 尾部 status 保持 deferred。下一轮 loop 进 Step 2 会看到 deferred 就继续 Step 3,允许 skill 挑下一条新 bug。但 processed.jsonl 里**不写 defer 的那条**,下次它还会被挑到。用户想彻底跳过就得手动 approve/reject。

### Step 3:已处理集合

```bash
jq -r '.message_id' state/processed.jsonl 2>/dev/null | sort -u > /tmp/bug-triage-processed-ids.txt
```

空文件也 OK,后面过滤时相当于全部通过。

### Step 4:拉群历史消息

**通过 Skill 工具调用 lark-im**,让它拉群历史。示例(实际参数以 lark-im skill 输出为准):

```
使用 lark-im skill 的 `+chats-messages-get` 命令,
参数:
- chat_id = <bug_chat_id from config>
- 时间范围:首次 = 现在-60 天到现在;后续 = 上次最新 processed_at 到现在
- 输出 NDJSON
```

**首次判断**:`[ -s state/processed.jsonl ]` 为 false → 走首次路径。

**注意**:lark-cli 拉历史消息可能有分页/rate limit,交给 lark-im skill 处理即可。

结果落到 `/tmp/bug-triage-raw.jsonl`。

### Step 5:过滤 + 挑一条

**过滤规则(顺序执行)**:
1. `msg_type ∈ {text, post}`(text/post 都保留,discard media/system/merge_forward/audio/video/sticker)
2. `reply_to == null`(只挑顶帖,回复/追问由 triage prompt 判定为 not_bug)
3. `message_id ∉ P`(排除已处理)
4. 按 `create_time` 新→旧倒序,取第一条

**注意**:lark-im 返回的字段是 `message_id`(不是 msg_id)。`create_time` 是 `"YYYY-MM-DD HH:MM"` 字符串,倒序前用 `string < string` 比较即可(格式规整)。lark-im 默认按新→旧返回,可以直接取 messages 数组首元素。

```bash
# 过滤 + 挑一条
jq -c --slurpfile p <(jq -R . /tmp/bug-triage-processed-ids.txt | jq -s .) '
  .data.messages[]
  | select(.msg_type == "text" or .msg_type == "post")
  | select(.reply_to == null)
  | select(([$p[0][] | .] | index(.message_id)) | not)
' /tmp/bug-triage-raw.jsonl \
  | jq -s 'sort_by(.create_time) | reverse | .[0]' > /tmp/bug-triage-target.json
```

若 `/tmp/bug-triage-target.json` = `null` → 无新的顶帖,追加 `state/loop.log`,退出。

### Step 6:判定 + 抽取

按 `prompts/triage.md` 由 LLM 自己判定。输入:target 消息 JSON + processed.jsonl 里最近 30 天 real_bug 的 title/module(用于语义去重)。

**Step 6 前置硬约束 (来自一次真实事故复盘, 违反视为不合格)**:

1. **附件 100% 提取**: 消息里所有 `![Image](img_xxx)` 必须用 `lark-im +messages-resources-download --file-key img_xxx --type image --output img.png` 下载, 每张图用 Read tool 打开 (视觉 OCR 会自动做), 提取 verbatim 文本纳入判定输入。**未提取任一张附件, 禁止进入 Step 6**。
2. **技术名词消歧**: 见 `prompts/triage.md` §输入完整性, 把用户话里每个技术名词映射到明确的仓库组件, 消歧完才能推进。
3. **投诉时间窗计算**:
   - 从消息 `create_time` 换算 unix 秒 (UTC+8, `TZ=Asia/Shanghai date -d '2026-01-02 11:19' +%s`)
   - 记 `report_ts_utc8`
   - 后续所有 SLS 查询默认窗口 = `[report_ts - 7200, report_ts + 7200]` (±2h)
   - 该窗口无数据 → 明确判"回顾性投诉", 扩窗到 `[report_ts - 7*86400, report_ts]` (最近 7 天), 找该 uid 最后一次相关操作

**not_bug / duplicate**:
```bash
cat >> state/processed.jsonl <<< '{"message_id":"...","processed_at":"ISO8601","verdict":"not_bug","reason":"..."}'
```
退出。

**real_bug**:抽取字段(见 triage.md 输出格式),进入 Step 7。

### Step 7:定位(worktree 隔离 + dynamic workflow 并发)

**Step 7 硬约束 (来自一次真实事故复盘, 违反 = inference 证据全降级)**:

- **任何"代码路径推理"必须先 Read 完整函数体** (从 `func` 签名到闭合 `}`), 不许只用 grep 到的一行推理其行为
- **调用链每一跳都要读**: 例如"A 调 B 调 C 里查 DB"这类结论, 必须把 A/B/C 三个函数体都 Read 过
- **禁止假设 signature**: 遇到别名 (如 `dao.Chat.DeleteAllMessages`) 必须 grep 到 receiver 的具体 dao 定义再读
- **只做过 grep 未读函数体的推理, 在报告证据表里必须标 tag=hypothesis**, 不许标 inference 或以上

**第一步:module → 候选仓扫描(必做,不许跳)**

**规则来自一次支付相关真实事故复盘**:AI 默认在主后端仓找根因,遇到独立微服务(subscription / memory 等)就抓瞎,浪费一整轮 workflow 才发现开错仓。因此:

1. **先扫 `<github_root>/*` 拿到你项目下所有候选仓的实际清单**:
   ```bash
   ls -d "${GITHUB_ROOT}"/*/ 2>/dev/null | xargs -n1 basename | sort
   ```
2. **读 `docs/config.md` § "涉及的仓库" 表**,拿到项目侧维护的 `仓库 → 主分支 → 模块归属` 映射。
3. **按 module 字段决定候选仓**(至少 1 个,可多个并开):
   - `module=pay` → 主后端仓 **加** 独立支付/订阅仓(比如 `*-subscription` / `*-billing` / `*-payment` / `*-iap`;仓名里含 pay/bill/sub/iap 关键字的都算候选)
   - `module=memory` → 主后端仓 **加** 独立记忆仓(仓名里含 memory/mem 的都算候选)
   - `module=recsys` → 独立推荐仓
   - `module=ios/android/web` → 对应客户端仓
   - `module=chat/character/audit` → 通常在主后端仓,但仍要扫一遍看有没有 `*-chat` / `*-audit` 之类独立服务
   - `module=infra/other` → 从主后端仓开始,若定位过程发现走不通,追加候选仓再开
4. **候选仓列表要打印给用户看**:哪些仓被选中、为什么选、哪些明确排除。这一步的输出应该像:
   ```
   module=pay → 候选仓: <backend>, <backend>-subscription
   理由: <backend>-subscription 是独立支付微服务, config.md 表里 module 归属 pay
   排除: <backend>-app (客户端), <backend>-admin (只读后台 UI)
   ```
5. 若定位中途 bug-analyze / grep 提示 "这看起来在别的仓" → **追加**开对应仓的 worktree(不推倒重开),继续跑。

**第二步:开 worktree**。

```bash
# 从 message_id 生成短哈希做 worktree 名(避免路径过长)
SHORT_ID=$(echo -n "<message_id>" | shasum -a 1 | cut -c1-8)

# github_root 从 config.md 读,默认 ~/github
GITHUB_ROOT="<github_root from config>"

# worktree 池根目录(集中管理,方便批量清理)
WT_POOL="${GITHUB_ROOT}/bug-triage-worktrees/${SHORT_ID}"
mkdir -p "${WT_POOL}"

# 为每个需要开的仓开一个 worktree(可能有多个,遍历第一步得到的候选仓列表)
for repo in "${CANDIDATE_REPOS[@]}"; do
  REPO_MAIN="${GITHUB_ROOT}/${repo}"
  REPO_WT="${WT_POOL}/${repo}"

  # 分支来源:必须查 config.md 的仓库映射表(§ "涉及的仓库")
  # skill 不猜分支,以 config.md 表为准
  DEFAULT_BRANCH=$(read_branch_from_config "${repo}")   # 伪代码: 从 config.md 表格提取
  if [[ -z "${DEFAULT_BRANCH}" ]]; then
    # 表里没写才退化用 origin/HEAD, 并 log 一条 WARN 让用户来补表
    DEFAULT_BRANCH=$(git -C "${REPO_MAIN}" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
      | sed 's|refs/remotes/origin/||' || echo main)
    echo "WARN: ${repo} not in config.md 仓库表, fallback to ${DEFAULT_BRANCH}" >> state/loop.log
  fi

  # 开一个 detached worktree(不新建分支,避免污染)
  git -C "${REPO_MAIN}" worktree add --detach "${REPO_WT}" "origin/${DEFAULT_BRANCH}"
done
```

**注意**:
- worktree 池路径 `${GITHUB_ROOT}/bug-triage-worktrees/${SHORT_ID}/<repo>` —— 集中在 github_root 下的一个子目录,不散落
- 用 `--detach + origin/<default_branch>` 而不是 branch:避免创建残留分支
- 只读:不 checkout 到新分支,不 commit,不 push
- **分支必须以 config.md 仓库表为准**,skill 不猜。如果表里没写,skill 会打 WARN 让你回来补表,不做静默默认

**Subagent prompt 硬约束(P1 规则,来自一次支付相关真实事故复盘)**:

若 Step 7 通过 Workflow / Agent 派子 agent 做定位,主 loop 在写 prompt 时必须做:

- **贴现网数据快照**:若已知 uid / <主键> / <交易键> / order_id 等实体,主 loop 应**先自己**做一次 bytebase 快查(SELECT * FROM 主表 WHERE 实体键 = ?),把结果原样嵌到子 agent 的 prompt "背景" 段。**子 agent 不负责去查主表看实体是否已存在**,那是主 loop 的活。
- **子 agent 的定位是"代码理解 + 数值推演",不是"数据获取"**:数据由主 loop 前置,子 agent 只做基于给定数据的推理。
- 若主 loop 因 MCP 暂时断连拿不到快照,应在 prompt 里明确写 "主表快照未拿到, 子 agent 请在假设分支里给出 A/B 两条推理路径" 而不是让子 agent 自己去查(避免子 agent 想当然)。

**反例(支付类事故)**:主 loop 让子 agent 判断"用户 <某交易键>=X 是不是同链续订",子 agent 没先查数据库直接假设 X 是首订 → 结论错。若主 loop 前置贴了"库里 uid 已有 <某交易键>=Y 旧订阅链记录, X 是新链"的快照,子 agent 就不会错。

**第三步:估证据源数量,决定串行 vs workflow**。

- 有 `affected_uid` → +1 SLS 源
- module ∈ {chat, memory, character, pay, audit} → +1 DB 源
- module ∈ {memory} → +1 memory 服务源
- 总是 +1 代码源

**证据源数 >= `workflow_min_evidence_sources`(默认 3) → 走 Dynamic Workflow**;否则串行。

**第四步:Dynamic Workflow 编排(证据源 >= 3 时)**。

使用 `Workflow` 工具,pipeline 4 个 agent 并发。每个 agent 拿到 WT_POOL 路径,自己 cd 进对应仓的 worktree 执行:

```javascript
export const meta = {
  name: 'bug-locate',
  description: 'locate bug via parallel agents across repos',
  phases: [{ title: '并行定位', detail: 'SLS/DMS/memory/代码' }],
}

const bug = <bug json from Step 6>
const wtPool = "<WT_POOL absolute path>"
const repos = <list of opened repos, e.g. ['<backend>', '<backend>-subscription']>

phase('并行定位')
const sources = [
  {
    key: 'sls',
    prompt: `使用项目侧 oncall/debug skill(或直接调 aliyun-sls MCP)从 SLS 查 uid=${bug.affected_uid} 最近 30 分钟 ${bug.keywords.join('/')} 相关日志。上下文: ${JSON.stringify(bug)}。只返回 <=5 条关键日志片段 JSON。`,
  },
  {
    key: 'db',
    prompt: `使用项目侧 oncall/debug skill(或直接调 bytebase MCP)从主库查 ${bug.module} 相关表 uid=${bug.affected_uid} 的状态。上下文: ${JSON.stringify(bug)}。返回相关行 JSON。`,
  },
  {
    key: 'mem',
    prompt: `使用项目侧 oncall/debug skill 直连 memory 服务(若有)查 uid=${bug.affected_uid} 的记忆数据。上下文: ${JSON.stringify(bug)}。返回 JSON。`,
  },
  {
    key: 'code',
    prompt: `使用 bug-analyze skill 定位相关代码。在 worktree 池 ${wtPool} 下的仓 ${repos.join('/')} 里跑,不要出 worktree。上下文: ${JSON.stringify(bug)}。返回 { repo, file, line, snippet, reasoning } JSON。`,
  },
]

const results = await parallel(sources.map(s => () =>
  agent(s.prompt, { label: `locate:${s.key}`, phase: '并行定位' })))

return results.filter(Boolean)
```

**串行路径(证据源 < 3 时)**:直接用 `Skill` 工具调项目侧 oncall/debug skill 再调 code-analyze skill,每次调用都传 wtPool 路径。

**第五步:worktree 清理(Step 13 里做)**。

不管定位成功失败,退出前清理**整个 WT_POOL**:
```bash
# 遍历 pool 里所有 repo worktree,逐个 remove
for wt in "${WT_POOL}"/*/; do
  REPO=$(basename "${wt%/}")
  REPO_MAIN="${GITHUB_ROOT}/${REPO}"
  git -C "${REPO_MAIN}" worktree remove "${wt%/}" --force 2>/dev/null || true
done
rmdir "${WT_POOL}" 2>/dev/null || true
```

### Step 8:实锤打分

按 `prompts/rubric.md` 打分。**严重度用 bug-analyze 的 critical/high/medium/low 四档**(triage.md 里已完成映射,不需要额外转换)。

**实锤度**是本 skill 独有的 5 档:confirmed/likely/needs-more-signal/insufficient/not-bug-after-analysis。

### Step 9:生成 review markdown

按 `prompts/report-format.md` 模板输出。**沿用团队现有 review comment 约定**(用 `<details>` 折叠长内容)。

### Step 10:写 review-queue

```bash
# 用 jq 拼装,避免 markdown 里的换行破坏 JSONL
jq -c -n \
  --arg message_id "..." \
  --arg title "..." \
  --arg verdict "real_bug" \
  --arg confidence "likely" \
  --arg severity "high" \
  --arg module "..." \
  --arg markdown "$(cat /tmp/review-markdown.md)" \
  --argjson evidence "$(cat /tmp/evidence.json)" \
  '{message_id: $message_id, processed_at: (now | todate), status: "pending_review",
    verdict: $verdict, confidence: $confidence, severity: $severity, module: $module,
    title: $title, markdown: $markdown, evidence: $evidence}' \
  >> state/review-queue.jsonl
```

### Step 11:展示 markdown

直接在对话中输出 Step 9 的 markdown。用户会看到。

### Step 12:飞书推送

若 `is_quiet == false`:**通过 Skill 工具调用 lark-im**:

```
使用 lark-im skill 的 `+messages-send` 命令,
参数:
- user_id = <my_open_id from config>
- text = "有 bug 待 review:{title}\n模块:{module} 严重度:{severity} 实锤:{confidence}"
- --as bot(推送用 bot 身份)
```

若 lark-im skill 有 Interactive Card 能力,后续 v2 可升级为带 approve/reject 按钮的卡片。**MVP 阶段先用纯文本**。

### Step 12.5:Handoff owner(verdict=confirmed 且存在存量待补 时必做)

**规则来自一次支付相关真实事故复盘**:确认 bug + 找到修复 commit 后,只写"建议调 recover"是不够的。真正闭环需要把**具体存量清单 + 处置人**都定位到,不然存量继续挂着。

若 verdict=confirmed 且证据显示"修复代码已存在但存量未自动补",Step 12.5 强制做以下动作:

1. **锁定修复 commit + author**:
   ```bash
   # 已知修复 commit hash(从 Step 7 code agent 输出里拿)
   git -C "${WT_POOL}/<repo>" show <fix_commit> --no-patch \
     --format='Author: %an <%ae>%nDate: %ad%nSubject: %s'
   # 顺便找 merge PR 号
   git -C "${WT_POOL}/<repo>" log --oneline --ancestry-path <fix_commit>..origin/<branch> --merges -3
   ```
2. **拉全量存量清单**(SLS 反查 + bytebase 交叉):
   - SLS 关键字 grep pre-fix 期间 bug 触发日志,抽出所有独立实体键(uid / <交易键> / order_id 等)
   - 对每个键去主表查一遍现网状态:"已恢复 / 未恢复"
   - 生成"未恢复存量清单"表(uid + 键 + 现网状态 + 上次触发时间)
3. **找处置人**:
   - 若 author email 是内部邮箱,用 `lark-contact +search-user --query "<author name>"` 找 open_id
   - 若找不到,先只标注 GitHub username,让用户手动接头
4. **生成 handoff 私信草稿**(不许自动发,交给用户 review):
   ```
   Subject: <bug 名>存量补发咨询
   Body:
     - 问题: 一句话
     - 根因: <file:line> 你 commit <hash> 已修
     - 存量: 共 N 个 uid 未补(附清单)
     - 追问: 是否有 admin backfill 接口 / 你能不能批量走 recover
   ```
   把草稿输出给用户,不主动发飞书。用户拷去自己发或授权后再发。
5. **写入 review-queue 尾部**:
   ```
   handoff: {
     to: "<owner name>",
     via: "飞书私信",
     affected_count: N,
     affected_uids: [...],
     fix_commit: "<hash>",
     fix_pr: "#XXX",
     draft_message_path: "state/handoff-drafts/<message_id>.md"
   }
   ```

**触发条件**:仅当 verdict=confirmed **且** action_items 里出现 "存量补" 类字样。verdict < confirmed 或纯代码修复无存量时,跳过 Step 12.5。

### Step 13:清理 worktree + 退出(verdict 每次升级都要重跑)

```bash
# 清整个 worktree 池
if [[ -n "${WT_POOL}" && -d "${WT_POOL}" ]]; then
  for wt in "${WT_POOL}"/*/; do
    [[ -d "${wt}" ]] || continue
    REPO=$(basename "${wt%/}")
    REPO_MAIN="${GITHUB_ROOT}/${REPO}"
    git -C "${REPO_MAIN}" worktree remove "${wt%/}" --force 2>/dev/null || true
  done
  rmdir "${WT_POOL}" 2>/dev/null || true
fi
```

日志:
```
[bug-triage-loop] message_id=<...> verdict=real_bug confidence=likely severity=high -> review pending
```

## 用户 review 后处理(下一次 loop 或用户手动触发)

Step 2 门禁前先检查上一条 pending_review 的状态:
- 若用户对话里最新一条明确回复 `approve` / `reject: <reason>` / `defer` → 更新 review-queue.jsonl 尾部,若非 defer 追加 processed.jsonl
- 若用户未回复 → Step 2 会门禁退出

**关键**:本 skill 的判断依赖用户对话上下文。如果 Claude Code 重启导致对话上下文丢失,可以手动:
```bash
# 编辑最后一条 review-queue 的 status
python3 -c "
import json, sys
lines = open('state/review-queue.jsonl').readlines()
last = json.loads(lines[-1])
last['status'] = 'reviewed_approved'
lines[-1] = json.dumps(last, ensure_ascii=False) + '\n'
open('state/review-queue.jsonl', 'w').writelines(lines)
"
```

## 错误处理

- **lark-im skill 失败**:重试 1 次,仍失败追加 state/loop.log 退出
- **项目侧 oncall/debug/code-analyze skill 或 MCP 失败**:降级为 verdict=needs-more-signal,markdown 里说明"定位失败原因"
- **本 skill 抛异常**:异常写 state/loop.log,不写 review-queue,下次 loop 重新挑同一 message_id(因未进 processed)

### MCP 反复 Stream closed 兜底(P1 规则,来自一次真实事故复盘)

若同一 MCP 工具在短时间内(< 5 分钟)连续 Stream closed **3 次或以上**,主 loop 不再盲目重试,而是主动切策略:

- **Read/Write 断** → 用 `Bash + heredoc` 或 `python3 -c` 落文件(功能等价,通道不同)
- **bytebase `query_database` 断** → 换 `call_api` 显式全路径(operationId=SQLService/Query + name=instances/<inst>/databases/<db>),这条通路和高层 API 走不同代码路径
- **aliyun-sls 某 region 断** → 换其他 region;若 query 语法(短语精确匹配)返回 0 而全文关键字有,换用宽松关键字
- **签署 3 次全断** → 该证据源标 tag=`tool_failure`,**不作为 absence signal 使用**;报告里显式列出"因工具不可用未验证"

### Subagent 兜底 wakeup fire 时的第一动作(P1 规则)

`ScheduleWakeup` fire 后,主 loop 不能盲目重排 wakeup 或直接下结论,必须先做:

1. **tail 子 agent output 后 50 行**判断死活:
   ```bash
   tail -n 50 <task_output_file>
   ```
2. 根据 tail 结果分三种情况:
   - **stopped / interrupted / 部分产出**:说明"部分产出 + 是否损失关键信息",然后决定"继续等 / 派新 agent / 主 loop 接管"
   - **still running**:贴一个进度快照给用户 + 再排一次 wakeup(delay 按剩余预期时长×2)
   - **completed 但通知丢失**:直接消费结果,推进后续 Step
3. 禁止在没做 tail 的情况下直接说"agent 还在跑"或"agent 死了"

### Verdict 升级时的重跑清单(P1 规则)

若某次 verdict 升级(如 likely → confirmed)或降级需要重开 worktree / 重跑 subagent,**Step 13 必须再跑一次**清理旧 worktree,防止泄漏。触发时机:

- verdict 落定当次(不论档次)—— 每次都跑
- verdict 后续被推翻/升级,导致重开 worktree —— 新 worktree 用完也要跑
- Skill 崩溃退出前 —— 兜底跑一次(可放 trap)

## 严格约束

- **本 skill 只处理一条消息**,绝不批量
- **本 skill 不修改任何项目源码**,只读
- **本 skill 只写 `state/`**,不动仓外
- **敏感数据脱敏**:手机号/邮箱/token 写 state 前用 sed 打码
- **所有飞书动作走 lark-* skill**,不裸调 lark-cli
- **所有生产数据源动作优先走项目 oncall/debug skill**,没有则直接调 MCP,不裸调 CLI
