---
name: logfire-ops
description: 用 Logfire MCP 做生产可观测性的看板运维与根因分析。四类能力：(1) 在现有 Logfire dashboard 里增/改/删 panel（Perses JSON 结构）；(2) 用 /loop 定期巡检看板与告警、对比基线、分析异常根因；(3) 按 trace_id 下钻捞全链路日志、定位根因并给出修复方案；(4) 基于历史数据做频率/影响面/SLI/趋势的量化分析，判断问题是否值得修。触发词：Logfire 看板/面板/panel/dashboard、加监控、定期巡检、监控告警、读告警群、根因/排查、trace 下钻、捞日志、值不值得修、量化分析、SLI/成功率。
---

# logfire-ops

用 Pydantic Logfire MCP 把「查日志 → 看板 → 巡检 → 根因 → 量化决策」串成一条可观测性运维流水线。

> 前置：已通过 `install.sh` 配好 `logfire` MCP server（HTTP transport + read token）。验证：`claude mcp list` 应看到 `logfire ... ✓ Connected`。没配就先跑本目录的 `install.sh`。

## 和 grafana-as-code 的边界（"读告警"歧义先看这里）

本 skill 与 `grafana-as-code` 都涉及"告警/看板"，但**监控对象不同，不要混用**：

- **logfire-ops（本 skill）= 应用层 telemetry**：Logfire alert 盯的是应用自身的 trace/日志信号（如 `Input is too long`、newapi 渠道缺失 503、sunrise 摘要失败/时延等），webhook 到飞书。看板是 Logfire dashboard（Perses）。
- **grafana-as-code = 基础设施指标**：Grafana alert 盯的是 ARMS Prometheus 指标（内存、circuit_state、时延桶、namespace 等）。告警走 `deploy/grafana/` 的 spec→generate→push。

**当用户只说"读一下线上告警 / 看看告警"未指明平台时**：默认理解为 Logfire 应用告警并用本 skill；但要**一句话点明边界**——"这是 Logfire 应用层告警；若你想看的是内存/时延/Prometheus 这类**基础设施指标告警**，那属于 grafana-as-code"。**不确定用户指哪层就先反问澄清**，不要默默猜一个就跑。

## 项目与连接

- Logfire 项目名：`tipsy`（id `64a539db-c13c-4bbd-b664-9882475c38de`）。
- 大多数工具需要 `project` 参数。若 read token 已绑定项目可省略；报错会提示可用项目名。
- 查询引擎 = Apache DataFusion（类 Postgres），数据主表 `records`、指标表 `metrics`。

## 四类能力 → 去哪查

按用户意图路由到对应 reference（**用到哪类再读哪个文件**，不要一次全读）：

| 用户想做 | 读这个 | 核心工具 |
|---|---|---|
| 写 / 调 SQL 查 records、捞日志、聚合统计 | `references/query-cookbook.md` | `query_run` |
| 在现有看板**增/改/删 panel**、新建看板 | `references/dashboard-panels.md` | `dashboard_get` / `dashboard_add_panel` / `dashboard_update_panel` / `dashboard_remove_panel` |
| **定期巡检**看板/告警、监控变化、读告警 | `references/monitoring-loop.md` | `/loop` + `alert_list` / `alert_history` |
| 按 **trace 下钻根因**、找解决方案 | `references/rca-trace.md` | `query_run`（trace_id）+ 读代码 |
| 判断问题**值不值得修**（量化） | `references/quant-decision.md` | `query_run`（聚合 + 趋势） |

一个完整排障往往串起多步：**告警/巡检发现异常 → trace 下钻定根因 → 量化判断优先级 → 建看板/告警长期盯**。各 reference 末尾有「下一步」指向衔接。

## 三条铁律（最容易踩的坑，先记住）

1. **有 ID 用 `->>` 精确过滤，禁止 `attributes::text ILIKE '%id%'` 全文扫**——极慢且模糊。`ILIKE` 只用于 `span_name` / `message` 的关键词模糊搜。
2. **4xx 的 `detail` 不进 span，只读 span 必误判**——HTTP 4xx/5xx 的错误信息通常在**应用层日志**（`message` / `attributes->>'error'` / `attributes->>'exception'`），不在顶层 `exception_*` 列（常为 null）。根因要顺着 trace 找应用层日志、必要时**回去读代码**，不要凭 span message 猜。
3. **始终加 `LIMIT`**，即使聚合查询；时间范围用 `start_timestamp/end_timestamp` 参数控制（最大 14 天，默认最近 30 分钟）。

## 典型对话 → 动作

- 「在 xxx 看板加个 5xx 趋势 panel」→ `references/dashboard-panels.md`：先 `dashboard_get` 拿现有 panel 当模板 → `dashboard_add_panel`。
- 「每 10 分钟巡检一下生产有没有新 5xx」→ `references/monitoring-loop.md`：`/loop 10m <巡检 prompt>`。
- 「这个报错帮我看下根因」（给了 trace_id / run_id / project_id）→ `references/rca-trace.md`。
- 「这个 bug 一天就几次，值得修吗」→ `references/quant-decision.md`：算频率 × 影响面 × 趋势。
- 「读一下线上告警 / 报警群」→ `references/monitoring-loop.md` 的「告警就是 Logfire alert」：飞书群读不到原文，源头在 `alert_list` / `alert_history`。

## 输出规范

- 给结论时附**证据**：trace_id、具体计数、时间窗、涉及 project/session。能给 Logfire UI 链接就用 `project_logfire_link` 生成。
- 区分「真问题 / 良性自愈 / 观测盲区」三态，别把瞬态自愈当事故。
- 写 SQL 先说要查什么、为什么这么过滤，再执行。
