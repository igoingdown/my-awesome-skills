# tipsy-studio / Logfire 相关问题 —— 转 logfire-ops skill

这份文档是 tipsy-oncall skill 的 references 分层文档，专门解决一个决策：当排障线索指向 tipsy-studio 或 Logfire 时，是本 skill 继续做，还是转 logfire-ops skill。它不深入讲 Logfire 运维本身，只做分流和防混淆。看到"tipsy-studio"、"sunrise"、"context compaction"、"newapi 503"、"Logfire 看板"这类关键词时先读这一份，再决定走哪条通道。

## 1. tipsy-studio ≠ tipsy-backend

tipsy-studio 是**独立 Python 仓**，不是 tipsy-backend 的子模块，也不共享代码。它负责聊天生成侧的 LLM 编排、prompt 管理、context compaction、sunrise（聊天记忆压缩）、AI coding agent 等能力。生产埋点全走 Logfire，Logfire 项目名 `tipsy`，项目 id `64a539db-c13c-4bbd-b664-9882475c38de`。

tipsy-backend 是 Go 服务，负责 HTTP API、SSE、鉴权、DB / 缓存、mempoint、character 元数据。生产埋点走 ARMS Prometheus + SLS，**不进 Logfire**。

看到"tipsy-studio"这个词，先做一次分流，别把 Python 侧当成 backend 的一部分去查。

## 2. 什么时候转 logfire-ops skill

以下触发词或场景，直接切到 logfire-ops：

- sunrise 生成失败、漏生成、压缩异常（事件名 `chat.sunrise.success` / `chat.sunrise.failed`）
- context compaction 报错、命中率异常
- AI coding agent 相关排查
- prompt 管理（prompt_get、prompt_list、prompt_create_version 等）
- newapi 上游 503、provider fallback 判定
- Logfire dashboard / panel / 告警新增或改动
- 需要按 trace_id 下钻 Python 侧全链路

logfire-ops skill 已经封装了 dashboard 增删改、告警巡检、trace 根因、量化 SLI，本 skill 不重复实现。

## 3. 什么时候本 skill 仍然要做

用户口头说"tipsy-studio 慢"，**先做一次反问**，别直接甩给 logfire-ops：

- 是"生成慢"（LLM 侧、Python 侧） → logfire-ops
- 还是"聊天接口慢"（HTTP API、Go 侧、SSE 首字节慢） → **本 skill 走 sls-logs / signoz / bytebase**

同理还有几类容易混的：

- "sunrise 没写进 mempoint" —— 要区分是 sunrise 没生成（logfire-ops），还是 sunrise 生成了但 backend ingest 挂了（本 skill 查 prod SLS + PG mempoint 表 + `$TIPSY_MEMORY_URL_PROD/v1/memory/ingest` 直连验证）
- "记忆没检索到" —— 大概率在 backend memory 服务侧，本 skill 直连 `$TIPSY_MEMORY_URL_PROD/v1/memory/retrieve`，不走 Logfire
- "回复截断 / SSE 断流" —— backend 侧问题，本 skill 查 SLS + signoz

判断准则：**用户报的现象最终落在 Go 侧还是 Python 侧**，落 Go 侧就本 skill，落 Python 侧转走。

## 4. 关键提醒:Go 侧指标不在 Logfire

写 tipsy-backend 告警或做量化分析时，**只查 ARMS Prometheus**（通过 aliyun-sls MCP 的 `cms_execute_promql`，或走 grafana-as-code skill 校准阈值）。不要用 Logfire `query_run` 去找 Go 服务的 QPS、时延、circuit_state、http vs gin 覆盖差异，查不到，或者查到的是错的样本源。

Logfire records 表里只有 Python 侧的埋点（sunrise、compaction、prompt 之类）。数据源别搞混，尤其在写告警规则的时候。

## 5. Logfire 基础信息一句话

- 项目名 `tipsy`，id `64a539db-c13c-4bbd-b664-9882475c38de`
- 常用 tool：
  - `query_run` —— SQL 查 records 表（例如按 `attributes->>'event'` 过滤 sunrise 事件）
  - `query_schema_reference` —— 拉表结构，忘了字段名先查这个
  - `alert_list` / `alert_history` —— 读告警定义和历史，改动仍走 logfire-ops

深度用法（dashboard panel 增删改、告警新建、trace 根因、SLI 计算）全部在 logfire-ops skill 里，不在本 skill 覆盖范围。

## 6. 案例

**sunrise 大规模失败**：用户反馈"聊天记忆断了、下一轮 AI 忘了刚才聊的"。

- 现象：飞书群贴出多个 chat_id，时间集中在同一小时
- 通道：tipsy-studio 侧问题 → **转 logfire-ops**
- 查询（在 logfire-ops 里做）：`query_run` 打 records 表按 `event='chat.sunrise.failed'` + 时间窗筛选，拿到 error 分布和触发条件
- 结论：属 tipsy-studio Python 侧，本 skill 只到"确认是 sunrise 生成失败、不是 backend ingest 挂"这一步就止步，根因和修复走 logfire-ops

## 7. 下一步 / 相关

- 深度 Logfire 运维、看板、告警、trace 下钻 → 调用 `logfire-ops` skill
- tipsy-studio 全景（数据源、sunrise 字段枚举、prod flag、飞书 webhook 三条路） → 项目记忆 `tipsy-studio-logfire-sunrise.md`
- Go 侧指标 / 告警 → `grafana-as-code` skill + 项目记忆 `metric-pitfalls.md`
- SLS 日志排查（mempoint / backend ingest / SSE 断流） → `references/sls-logs.md`