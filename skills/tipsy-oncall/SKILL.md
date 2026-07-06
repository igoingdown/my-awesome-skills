---
name: tipsy-oncall
description: >
  Tipsy 后端全链路值班排障 skill。集成 Bytebase MCP / aliyun-sls MCP / SigNoz MCP /
  Logfire MCP + Redis RunCommand OpenAPI + ES REST + Coolify CLI + nimbalyst-browser
  Chrome 兜底，覆盖 MySQL / PostgreSQL / Lindorm / Redis / Elasticsearch / SLS 日志 /
  ARMS Prometheus 指标 / APM / trace / 部署状态,并做 prod / test / preview 环境隔离。
  触发词:"查数据库"、"查日志"、"mempoint"、"记忆"、"聊天记录"、"账单"、"线上数据"、
  "为什么没入库"、"测试环境"、"预览环境"、"排查"、"值班"、"oncall"、"redis"、"es"、
  "部署状态"、"trace"、"熔断"、"告警根因"、"P99"、"错误率"。凭证走
  ~/github/my_dot_files/secrets.sh(token/AK/SK 不落盘)。输出结论严格按「现象 / 通道 /
  查询 / 结论 / 后续」五段格式。
---

# tipsy-oncall

Tipsy 后端值班排障流水线。**只做排查、不做变更** —— 所有查询默认只读,写操作(propose_database_change / 改配置 / 部署) 一律禁用,除非用户显式点名。

> 前置:已通过 `install.sh` 配好 4 个 MCP(`bytebase` / `signoz` / `logfire` / `aliyun-sls`)、装好 `coolify` CLI、把 secrets.sh 追加块的值填好。验证:`claude mcp list` 应看到 4 个 `✓ Connected`,`coolify --version` 应有输出,`echo $ALIYUN_ACCESS_KEY_ID` 不为空。

## 和其它 skill 的边界

- **本 skill = 排查(读为主)**:定位问题、验证数据、串 trace。
- **grafana-as-code = 基础设施告警/看板变更(写为主)**:加/改 Prometheus 告警规则、推看板、校准阈值 —— **写告警前必先跳过去读它的 references/alerting.md 铁律**。
- **logfire-ops = tipsy-studio 应用层可观测性**:tipsy-studio 是**独立 Python 仓**,跟 tipsy-backend 是两套系统 —— sunrise / context compaction / AI coding agent 相关的一律走 logfire-ops,别混。

**"读一下线上告警"歧义处理**:先反问指哪层 —— 基础设施(内存/时延/circuit_state) → grafana-as-code;应用 telemetry(tipsy-studio 的 chat.sunrise / newapi 503) → logfire-ops;tipsy-backend Go 侧的报错/异常 → 本 skill 走 SLS。

---

## §0 决策树 —— 用户问什么就走哪条

```
数据不对 / 没入库 / mempoint / 聊天原文 / 账单
├─ MySQL(业务表, tipsy/fantasy)      → references/mysql-postgres.md
├─ PostgreSQL(tipsy_memory)          → references/mysql-postgres.md
├─ Lindorm(聊天原文, 账单)           → references/lindorm.md
└─ Redis(缓存, pending 队列, limiter) → references/redis.md

报错 / 堆栈 / trace_id 下钻
├─ tipsy-backend(Go)                 → references/sls-logs.md
├─ tipsy-memory(Python)              → references/signoz.md
├─ 多服务串联                        → references/trace-crosslink.md
└─ tipsy-studio                      → 转 logfire-ops skill

性能 / P99 / 错误率 / 熔断 / 告警根因
├─ ARMS Prometheus 指标              → references/prometheus.md
├─ 陷阱防护(必读)                    → references/metric-pitfalls.md
└─ 校准阈值 / 加改告警               → 转 grafana-as-code skill

角色可见性 / ES 同步 / 推荐位空
└─ Elasticsearch                     → references/elasticsearch.md

memory 服务黑盒验证
└─ 直连 curl retrieve/summary        → references/memory-direct.md

测试环境挂了 / 预览地址打不开
├─ 定位预览环境 tag                  → references/environments.md
├─ K8s 主链路(tipsy-backend/memory)  → references/sls-logs.md(查 pod 启动日志)
└─ Coolify 上的副服务                → references/coolify.md
```

不确定该读哪份就先读 `references/decision-tree.md`(完整版决策流)。

---

## §1 铁律 —— 任何操作都适用,违反必出事

1. **只读默认**:排查阶段禁用 `propose_database_change` / 改配置 / 手动重启 pod / 手动 delete 记忆等。要变更转对应 skill(grafana-as-code / 直接改代码 + PR)。
2. **prod / test / preview 三环境隔离**:每次查询前先说清"查的哪个环境",实例名/database/URL 都跟环境绑定。混用会给出错误结论。
3. **UTC vs UTC+8**:数据库 `created_at` 是 UTC,SLS/北京时间是 UTC+8,对比时序前先对齐,别默认相等。
4. **token / AK/SK 不落盘**:所有敏感值从 `source ~/github/my_dot_files/secrets.sh` 注入,**绝不 `echo`、绝不写 .env、绝不进 commit**。
5. **比率查询必 `clamp_max(...,1)`**:PromQL 分母兜底 `1e-7` 会把小样本放大成天文数字 —— 低流量维度用 `and on(...)(sum by(...) > 阈值)` 门槛。
6. **多副本 Gauge 必聚合**:`max by(provider, account_id)` / `sum by(app)`,别拿裸指标下结论。`tipsy_anthropic_circuit_state` **1 = 可用 / 0 = 熔断**(反直觉,llmdoc 一度写反)。
7. **HTTP 时延指标覆盖不全**:`tipsy_http_request_duration_seconds` **只覆盖 chat 路由**,订阅/webhook 走 `gin_request_duration_seconds`(10s 桶)。Core Payment 告警别用错。
8. **mempoint 成功路径 backend 静默无日志**:SLS 零结果 ≠ 没入库,直接查 tipsy_memory PG 或 curl `/v1/memory/retrieve` 验证。
9. **五段报告是硬约束**:见 §3。

---

## §2 前置 —— 每次操作前的通用姿势

```bash
# 1. 注入 env(所有 URL/AK/token 都从这里出)
source "$HOME/github/my_dot_files/secrets.sh"

# 2. 快速自检(缺哪个就停一下让用户先填 secrets.sh)
: "${ALIYUN_ACCESS_KEY_ID:?secrets.sh 未注入 ALIYUN_ACCESS_KEY_ID,先跑 install.sh}"
: "${TIPSY_MEMORY_URL_PROD:?secrets.sh 未注入 TIPSY_MEMORY_URL_PROD}"

# 3. 明确环境 —— 每个 skill 调用前问用户 "查 prod 还是 test?"
ENV="${ENV:-prod}"   # prod | test | preview
```

**MCP 断线自愈**:`bytebase / logfire / aliyun-sls` 偶发 Stream closed —— 等 15s 会重连,或提示用户浏览器打开 `https://bytebase.infra.fantacy.live/mcp` 重授权。别在断线状态空转。

---

## §3 输出规范 —— 五段报告(硬约束)

**每次给用户结论时**必须按下面模板填空。不允许省略、不允许改段名、不允许合并段落。查询过程中的中间输出不用套模板,只有**最终结论**要。

```markdown
## 现象
(用户报的一句话现象 + 时间窗 + 环境。示例:"prod 环境,过去 30 分钟,角色 xxx 在 trending 页消失")

## 通道
(走了哪 1-3 个查询通道,为什么选它。示例:"MySQL 编辑历史表看是否被回退 + ES 索引看是否同步失败")

## 查询
(每个通道的关键命令 + 精简结果。命令用占位符,不含真实 URL/token。示例:
- `mcp__bytebase__query_database(database='tipsy', statement='SELECT ...')` → 3 行
- `curl $ALIYUN_ES_ENDPOINT_PROD/character/_search -d '{...}'` → hits=0)

## 结论
(**一句话**,判定是否真的存在问题、根因指向哪。示例:"问题真实存在,ES 索引没同步,MySQL 有数据但 ES hits=0")

## 后续
(1-3 条 actionable。示例:
1. 用户可尝试重新触发同步:调 `/api/v1/character/reindex?id=xxx`
2. 若需长期修:改 sync worker 加重试 —— 建 ticket 到 tipsy-backend
3. 补充证据可以查:tipsy_memory PG 的 sync_log 表看是否有失败记录)
```

**为什么硬约束**:值班场景要给用户/其他工程师一个**能快速消费、能被机器再解析**的结论;历史上"现象+结论"混写的报告导致过多次误判 —— 五段是 v1 的最低约束。

---

## §4 常用一键脚本(scripts/)

在 skill 目录下 `scripts/` 有可执行封装,任务里直接 `bash scripts/xxx.sh` 调用:

| 脚本 | 用途 |
|---|---|
| `env-detect.sh [tag\|preview-url]` | 无参=三环境 secrets 注入全景;带参=预览环境探活 |
| `redis-cmd.sh <env> <cmd> [args...]` | R-KVStore RunCommand 一键封装(GET/HGETALL/SCAN/TTL),实例 ID 从 env 变量读 |
| `es-search.sh <env> <index> <query-json\|-> [--op <op>]` | ES REST 一键 curl,`-` 从 stdin 读 query |
| `memory-retrieve.sh <env> <session-id> [character-id] [action]` | `/v1/memory/{retrieve,summary}` curl |
| `coolify-status.sh [app-uuid]` | app/service 状态汇总(JSON) |
| `mempoint-timeline.sh <env> <session-id> [character-id]` | mempoint 区间/dedup/reset 时间线 |
| `trace-crosslink.sh <trace-id> [env] [time-range]` | SigNoz + Logfire + SLS 三路拉齐 |

脚本统一 source `~/github/my_dot_files/secrets.sh`(可用 `TIPSY_ONCALL_SECRETS_FILE` 覆盖路径),不带任何默认 URL/token。

---

## 收尾

- 各能力的故障速查、字段字典、真实查询模板在 `references/*.md`,**按需读**,不要一次全加载。
- 遇到 skill 里未覆盖的场景(比如新加了 Kafka / Milvus),先记录在报告的「后续」段,再补充到 skill 里 —— 不要硬编在结论里。
- 改完 SKILL.md 或 references/*,记得跑 `bash ~/github/my-awesome-skills/sync.sh` 同步到 `~/.claude/skills/` 和 `~/.agents/skills/`。
