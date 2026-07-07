# bug-triage-loop

个人 AI **Bug Triage Agent** — 用 Claude Code `/loop` 每 N 分钟拉一次飞书 Bug 群消息,判定 / 定位 / 生成 review markdown 让你 approve,**严格串行、单人操作、零部署**(只用 Claude Code + `lark-cli` + 你项目已有的 oncall/debug/code-analyze skill 或直接调 MCP)。

## 定位

- **不是**团队协作平台(那种走 Bitable + 多角色 + Interactive Card 的方案不在本 skill 范围)
- **是** AI 秘书:替你盯群、挑真 bug、跑定位、生成 review markdown、等你 approve

## 依赖

- Claude Code(本机运行)
- `lark-cli`(已登录 bot + user 双身份;auth 走 `~/.claude/skills/lark-shared`)
- 你项目侧的 oncall / debug / code-analyze skill(可选),或直接调 `bytebase` / `aliyun-sls` / `signoz` / `logfire` MCP
- **没有其他依赖**:不用 Docker、pgvector、Redis、数据库、Bitable

## 快速上手

```bash
# 1. 装 skill
./sync.sh    # 或 cp -R skills/bug-triage-loop ~/.claude/skills/

# 2. 配置(第一次运行前)
cd ~/.claude/skills/bug-triage-loop
$EDITOR docs/config.md      # 填 3 个 FILL_ME:bug_chat_id / my_open_id / github_root
                             # 并维护 §"涉及的仓库"表(module → 仓 → 主分支 映射)
$EDITOR docs/setup.md       # 按步骤走一遍(MCP 前置 + worktree 约定)

# 3. 手动跑一轮验证
claude "/bug-triage-loop"

# 4. 挂上 /loop 自动跑
claude "/loop 5m /bug-triage-loop"
```

看 [docs/setup.md](docs/setup.md) 详细步骤。

## 目录结构

```
skills/bug-triage-loop/
├── SKILL.md                       # /bug-triage-loop skill 定义(供 Claude Code Skill 工具索引)
├── README.md                      # 本文件
├── prompts/                       # LLM prompt 素材
│   ├── triage.md                  # 判定是不是 bug + 结构化抽取
│   ├── rubric.md                  # 5 档实锤 rubric + 证据分级
│   └── report-format.md           # 给你 review 的输出格式(含 § 修复与存量状态)
├── docs/
│   ├── setup.md                   # 启动手册
│   └── config.md                  # bug 群 chat_id / my_open_id / github_root / 仓库表 / 静默时段等
└── state/                         # 运行时状态(**含真实事故内容,不进公开仓,只本地或私有仓**)
    ├── processed.jsonl            # 已处理 message_id 记录
    ├── review-queue.jsonl         # 你 review 过的完整分析归档
    ├── loop.log                   # 每轮 loop 简要日志
    └── handoff-drafts/            # confirmed 报告的 owner 私信草稿(不自动发)
```

## 设计原则

1. **严格串行**:review 完才处理下一条,不并发。
2. **单文件存储**:JSONL 就够,不引入数据库。
3. **零部署**:Claude Code 就是运行时,不用 Docker/systemd。
4. **/loop 是调度器**:关电脑停摆,开电脑启动,天然可用。
5. **每轮独立**:每次 loop 是一次完整"读状态→拉消息→处理一条→写状态"的原子操作。

## 精度硬约束

来自两次真实事故复盘(一次 absence-signal 类事故导致多次翻案 + 一次支付相关事故开错仓 + 存量未补)。**不遵守直接导致误报或错案**。

- **证据分级 tag**:`ground_truth / strong_signal / absence_signal / inference / hypothesis` 五档,定义见 `prompts/rubric.md`
- **`confirmed` 三方齐门槛**(严于旧版):必须同时有
  - ≥1 条 ground_truth 来自**现网数据**(bytebase / DMS / Lindorm / 精确 uid+trace 的 SLS)
  - ≥1 条 ground_truth 来自**代码**(完整函数体已读,不是 grep 一行)
  - ≥1 条 ground_truth 来自**修复线索**(修复 commit / PR / 已存在的 workaround / backfill 接口)
  - 三方数值 / 时间戳 / uid 一致
- **absence signal 单独不能到 confirmed**,使用前必须先做全局命中数 sanity check + 参数/时区/单位排除
- **附件 100% 提取 + 技术名词逐个映射到明确仓库组件**(`prompts/triage.md` § 输入完整性)
- **投诉时间窗 = 上报时间 ± 2h**(`SKILL.md` Step 6 前置约束);该窗无数据 = 回顾性投诉,扩窗到最近 7 天
- **代码路径推理必须先 Read 完整函数体**(`SKILL.md` Step 7 硬约束),只 grep 不算数
- **module → 候选仓扫描**(Step 7 第一步):必须先扫 `<github_root>/*` 得候选仓列表,不许默认"chat/pay/memory 都归主后端";独立微服务(`*-subscription` / `*-payment` / `*-memory` 之类)必须一起开
- **子 agent 硬约束**:主 loop 前置贴现网数据快照,子 agent 只做代码理解 + 数值推演,不做数据获取(防"想当然")
- **每份报告必须有"对抗式自检"段**(`prompts/report-format.md`):现有证据里最弱 3 条 + 反命题能否成立 + 什么新数据能证伪 + 时区对齐 sanity check + 完整函数是否都读
- **`confirmed` 报告必须有"修复与存量状态"段**:修复 commit + author + 部署时点 + 存量补救调用次数 + 本 uid 现网状态 + 全量存量清单
- **Step 12.5 handoff owner**:verdict=confirmed 且存量待补时,自动锁定修复 commit author + 生成私信草稿(不自动发)
- **MCP 反复 Stream closed 兜底**:连续 3 次断连主动切通路(Read → Bash heredoc / bytebase query → call_api / SLS 换 region);3 次仍失败标 tag=tool_failure,不作 absence signal
- **subagent 兜底 wakeup fire 第一动作**:先 tail output 后 50 行判断死活,不盲目重排 wakeup 或直接下结论
- **verdict 升级重跑 worktree 清理**:每次 verdict 落定 / 升级 / 崩溃退出前都要重跑 Step 13

## Backlog(长期)

- **建议 6 — 对抗验证 subagent**:lead agent 给初判后立刻起 1 个 subagent 专门反驳("用相同数据尝试建立相反假设"),只有反驳失败才算 likely 及以上。触发条件、subagent prompt、成本控制待设计。
- **建议 7 — 证据集持久化**:每次真调 SLS/DB 拿到的原始返回存到 `state/evidence/<message_id>/*.json`,后续推理必须引用这些 evidence 的具体 hash/时间戳。翻案时能溯源"当时基于什么数据得出错结论"。待设计:落盘格式、脱敏、清理策略。
