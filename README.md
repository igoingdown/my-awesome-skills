# my-awesome-skills

A collection of awesome skills built for Claude Code.

## Installation

Clone the repository and install dependencies:

```bash
git clone https://github.com/igoingdown/my-awesome-skills.git
cd my-awesome-skills
npm install
```

## Usage

Each skill lives under `skills/`. Install a skill by placing its directory into your Claude Code skills folder.

## Skills

### OpenRouter Balance

Query OpenRouter account balance and send Feishu notification.

使用说明：[skills/openrouter-balance/README.md](skills/openrouter-balance/README.md)

### New API Usage

查询 new-api / one-api 系 LLM 网关的**当日用量**并推送飞书私聊：
- 按模型聚合：美元花费 / tokens / 调用次数，附账户余额
- 每小时定时执行（macOS launchd / Linux cron 均支持）
- 推送降噪：用量无变化不重复推送，跨天自动重置
- token 失效自动推 ⚠️ 告警（同一错误只推一次）
- 敏感配置（实例地址 / 令牌 / 用户 id / 接收人 open_id）全部走仓库外的 secrets 文件

使用示例：在 Claude Code 里说
> "今天 LLM 用了多少" / "配一下每小时用量推送"

使用说明：[skills/newapi-usage/SKILL.md](skills/newapi-usage/SKILL.md)

### CodeX Adversarial Review

把 spec/设计方案、代码/PR 交给**外部 CodeX CLI** 做对抗式独立评审（独立模型、独立读码、职责是证伪而非附和），适合"方案已定将开工"或"代码写完将合入"的最后一道门。

使用示例：在 Claude Code 里说
> "把这个方案发给 CodeX review" / "合入前找 CodeX 挑挑刺"

使用说明：[skills/codex-adversarial-review/SKILL.md](skills/codex-adversarial-review/SKILL.md)

### IPP Print

macOS 上通过 IPP 协议直连办公室网络打印机打印 PDF，并在**打印机侧**做真实出纸验证：
- 网段扫描发现打印机 IP、检查状态/能力
- 加密 PDF 自动重写后再发（部分打印机拒收加密 PDF）
- 打印失败排查手册（CUPS 显示 completed 但没出纸等经典坑）

使用说明：[skills/ipp-print/SKILL.md](skills/ipp-print/SKILL.md)

### Long Task Manager

面向大 spec/plan 文档的长任务执行管理：初始化持久化 `state.md`、管理进度、把重上下文工作委派给 subagent/workflow、compaction/resume 后自动恢复，直到完成或遇到可证明的 blocker。

使用说明：[skills/long-task-manager/SKILL.md](skills/long-task-manager/SKILL.md)

### Volcengine Balance Check

查询火山引擎账户消费信息（余额/账单），凭证走环境变量。

使用说明：[skills/volcengine-balance-check/SKILL.md](skills/volcengine-balance-check/SKILL.md)

### Vultr Balance Check

查询 Vultr 账户余额和当月待扣费用，凭证走 `.env`（不进仓库）。

使用说明：[skills/vultr-balance-check/SKILL.md](skills/vultr-balance-check/SKILL.md)

### Interview Comment

面向**后端/算法/大数据研发**岗位的严格面试评价生成器：
- 固定目录结构：`<人名>/001 002 003 .../`，每轮一个子目录
- 固定文件命名：`resume.png`（简历）/ `asr.md`（语音转文字）/ `review-res.md`（其他面试官评价文本）
- 五维定性判断（业务理解/技术支撑/技术广度/技术深度/软素质），每维 `+`/`=`/`-` 标注
- 七档综合评分（2.5 / 2.75 / 3 / 3.25 / 3.5 / 3.75 / 4），**3+ = ≥3.25 通过**
- 跨轮交叉参考：自动读取其他轮次 `review-res.md`，对本轮独立判断做**补充 + 校正**（先独立再参考、分歧时证据驱动 + 严格优先）
- 证据驱动：每个标注、优点、风险都引用 `asr.md` 原话或简历原文
- 严格机制：borderline 一律按低档打（3 和 3.25 之间犹豫 → 打 3 不通过）
- 输出：`<人名>/<目标轮>/evaluation.md`（按团队模板结构化）

使用示例：在 Claude Code 里说
> "评估 `~/interviews/zhang-san`，我做的是 2 面"

使用说明：[skills/interview-comment/SKILL.md](skills/interview-comment/SKILL.md)

### Family Travel Planner

带宠物家庭自驾旅行规划工具，支持：
- 避峰日期推荐（基于 GaoDe API + 拥堵系数）
- 自驾方案（路线规划 + 充电计划 + 区域住宿推荐 + 景点推荐）
- 火车方案（宠物乘车/托运政策调研）
- 方案对比（6维度对比表：耗时/成本/宠物压力/灵活度/政策风险/避峰难度）
- 避峰评估（拥堵降低 X% ±15%）

使用示例：
```bash
cd skills/family-travel-planner
npm install && npm run build
cp .env.example .env
# 编辑 .env，填入 GaoDe API Key
npm start -- --origin 北京 --destination 大连 --days 5 --holiday 五一
```

集成 OpenClaw 后，可在飞书上直接说：
> "帮我规划五一北京到大连的旅行，带狗，开 Model Y"

技术栈：TypeScript + GaoDe Map API + OpenClaw

使用说明：[skills/family-travel-planner/README.md](skills/family-travel-planner/README.md)

### Grafana as Code

Tipsy 后端的「告警即代码 / 看板推送 / 阈值校准」操作 skill（**薄编排**，不复制脚本，
只负责加载凭证、定位仓库 `deploy/grafana/` 脚本、跑现成工具，并把历史踩坑固化成护栏）：
- 告警：`alerting/`（tipsy-backend）+ `alerting-recsys/` 的 DRY `spec → generate → validate → push`（Provisioning API）
- 看板：`push_dashboard.py` 导入/更新看板 JSON（经典 `/api/dashboards/db`）
- 阈值校准/诊断：`diagnostics/*.py` 只读查 ARMS Prometheus，写阈值前先查真实 series

凭证走 `~/github/my_dot_files/secrets.sh`（`GRAFANA_URL` / `GRAFANA_TOKEN`，token 不落盘）。
安装：`./skills/grafana-as-code/install.sh`（含依赖与凭证体检）。

使用示例：在 Claude Code 里说
> "给 voice call 加一条 Agora 离会失败率告警" / "内存告警在误报，帮我校准阈值"

使用说明：[skills/grafana-as-code/README.md](skills/grafana-as-code/README.md)

### Logfire Ops

用 Pydantic Logfire MCP 把「查日志 → 看板 → 巡检 → 根因 → 量化决策」串成一条生产可观测性运维流水线（**分层 skill**：`SKILL.md` 入口路由 + 5 个按需加载的 `references/`）：
- 查询 / 捞日志：`query_run` 查 `records`（含 schema、过滤铁律、配方）
- 看板 panel 增改删：基于真实 Perses JSON 模板，增/改/删 panel、建看板、配变量
- 定期巡检 + 告警：`/loop` 周期巡检 + Logfire alert（读告警 = 读 Logfire，不是飞书群）
- trace 根因分析：按 trace 下钻 → 读应用层错误 → 回代码验证 → 给方案
- 量化决策：频率 × 影响面 × 严重度 × 趋势，判断值不值得修

依赖 `logfire` MCP server（HTTP transport + Logfire read token，token 不落盘）。
安装：`./skills/logfire-ops/install.sh`（复制 skill + 配置/体检 MCP）。

使用示例：在 Claude Code 里说
> "读一下线上告警" / "在 ddd 看板加个 5xx 趋势 panel" / "这个报错帮我看下根因（trace_id ...）" / "这个 bug 一天就几次，值得修吗"

使用说明：[skills/logfire-ops/README.md](skills/logfire-ops/README.md)

## License

MIT
