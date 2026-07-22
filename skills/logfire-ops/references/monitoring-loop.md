# monitoring-loop：定期巡检 + 告警

两件事：(A) 用 `/loop` 让 Claude 周期性巡检看板/日志并分析异常；(B) 用 Logfire alert 做服务端常驻告警。两者互补——alert 负责 7×24 兜底通知，/loop 巡检负责带上下文的主动分析。

## A. 用 /loop 做周期巡检

`/loop` 是 Claude Code skill，按固定间隔重复跑一个 prompt 或 slash 命令：

```
/loop 10m <巡检 prompt 或 /slash 命令>
```

- 间隔写法：`5m` / `10m` / `30m` / `1h`，默认 10m。
- 适合：盯部署、盯成功率、周期性扫新 5xx/告警。
- **不要**用于一次性任务。
- 巡检 prompt 要**自包含**（每轮是独立上下文）：写清查什么、基线是多少、发现异常怎么深挖、产出什么。

### 可直接用的巡检 prompt 模板

```
巡检 tipsy 生产可观测性（最近 30 分钟，deployment_environment='prod'）：
1. 用 query_run 统计 5xx 与异常：按 http_route / span_name 分组计数（带 LIMIT）。
2. 用 alert_list 看 5 条规则的 last_run / has_matches；对 has_matches=true 的用 alert_history(filter_matches=true) 拉触发明细。
3. 与基线对比（基线见下）。只报「新增 / 超基线 / 首次出现」的异常，自愈/已知良性的一句话带过。
4. 对每个真异常：捞 1 条代表性 trace_id，按 trace 下钻到应用层错误（attributes->>'error' / exception），给出疑似根因 + 是否需要人工介入。
5. 产出：一段简报（健康/警示/事故三态分类），每条结论附 trace_id 与计数。无异常就回「✅ 正常，关键指标在基线内」。
```

基线（随项目演进更新，写进巡检 prompt 里）：
- prod 整体 2xx ≈ 99.8%，全程应 0 个未自愈 5xx。
- 已知良性：偶发瞬态 5xx 自愈、探针打 test web `/` 长期 500、sunrise timeout 偶发降级（良性）。
- 判据：**多接口同刻 5xx + QueuePool exception = 共享连接池打满**（非单接口 bug）；**审核类 403 看 audit.rejected 日志不看 span**。

### 巡检铁律

- **别只盯 ERROR（level 17）**：很多失败是 INFO/WARN 级或 200 流内的应用层失败（如 SSE 端点失败裹在 200 里），按**行为特征**查（如 `POST 时延异常`、`agent run 轮数`），不要只 `WHERE level=17`。
- **瞬态自愈 ≠ 事故**：撞了一下立刻恢复、不复发的，归「良性」，别拉响警报。
- **新异常才深挖**：每轮先和基线 diff，把精力放在新增/超阈值的，避免重复分析同一已知项。

## B. Logfire alert（服务端常驻告警）

### 读告警 = 读 Logfire，不是读飞书群

飞书告警群**读不到原文**（webhook bot 发的卡片，OpenAPI 历史消息接口返回空；`search:message` scope 被禁）。用户说「读报警群/分析最新告警」时，真正的源头是 Logfire：

- `alert_list(project="tipsy")` → 所有规则 + 每条的 `last_run` / `has_matches` / `has_errors`。
- `alert_history(alert_id=<uuid>, filter_matches=true, start_timestamp=, end_timestamp=)` → 某规则的历次触发明细。

### tipsy 现有 5 条规则（均 webhook 到飞书）

| id 前缀 | 级别 | 盯什么 | 触发逻辑 |
|---|---|---|---|
| `a9f79087` | P0 | 上下文墙 `Input is too long`（用户硬失败） | `is_exception` + message/exception LIKE，`span_name LIKE 'chat %'` |
| `3f763fc2` | P1 | newapi 渠道缺失 503 `No available channel` | `chat.provider_error` + `No available channel`，按模型分组，总数≥5 才触发 |
| `86e3460a` | P1 | Sunrise 契约违规（防护型，0 次） | `chat.sunrise.contract_violation` |
| `f3f7d265` | P1 | Sunrise 摘要失败降级 | `chat.sunrise.failed` 按 `fallback_reason` 分组，grand_total≥3 |
| `20a39322` | P2 | Sunrise 时延 P95>100s | `chat.sunrise.success` 的 `duration_ms` p95，样本≥5 |

### alert 规则的结构（建/改告警时照抄）

`alert_create` / `alert_update` 的核心字段：

| 字段 | 含义 | 例 |
|---|---|---|
| `name` | 规则名（建议带 `[P0]`/`[P1]`/`[P2]` 前缀） | `[P1] newapi 渠道缺失 503` |
| `description` | 写清：盯什么、口径、正常基线、命中后怎么处置 | 见现有规则，描述里就把 runbook 写进去 |
| `query` | SELECT；**用聚合 + `HAVING/WHERE total>=N` 过滤孤立偶发**，避免单条噪声刷屏 | 见下 |
| `time_window` | 评估窗口（ISO 8601 duration） | `PT1H` / `PT10M` / `P1D` |
| `frequency` | 多久评估一次 | `PT15M` / `PT10M` / `PT1H` |
| `watermark` | 数据延迟补偿 | `PT1M` |
| `notify_when` | 按条件形态选,见下方设计要点 | `has_matches` / `starts_having_matches` |
| `channels` | 通知渠道（飞书 webhook 已配，复用现有 channel id） | `0e41be0c-...` |
| `environments` | 限定环境，空=全部（规则里多在 query 内写 `='prod'`） | `[]` |

设计要点：
- **window 与 frequency 对齐**（如都 `PT10M`）可避免重复计数/刷屏。
- **`notify_when` 按条件形态选**：突增/事件类条件（正常时 query 无结果）用 `has_matches`；「一旦出现会连续多个窗口持续命中」的**状态类条件**（存量脏数据存在、水位超限、某配置缺失）用 `starts_having_matches`——只在从无到有的边沿报一次，否则每个评估窗口都重发同一条告警轰炸群。要同时感知恢复用 `has_matches_changed`。真实教训：一条状态类告警配成 `has_matches`，配上就每窗口重复报，修法就是改 `notify_when`，而不是反复调阈值。
- query 里**带上命中条数 + 关键维度**（模型名/route/reason），这样飞书卡片正文就有上下文。
- 阈值留余量过滤正常波动（如「7 天约 5 次」就设 1h 内≥3 才报）。

建告警示例（5xx 突增）：

```jsonc
alert_create(
  project = "tipsy",
  name = "[P1] prod 5xx 突增",
  description = "近10分钟 prod 5xx 总数≥10 触发。正常应≈0。命中后按 route 看分布，捞 trace 下钻应用层 error。",
  query = "SELECT http_route AS route, count(*) AS cnt, sum(count(*)) OVER () AS total FROM records WHERE deployment_environment='prod' AND http_response_status_code>=500 GROUP BY http_route HAVING sum(count(*)) OVER () >= 10 ORDER BY cnt DESC",
  time_window = "PT10M",
  frequency = "PT10M",
  watermark = "PT1M",
  notify_when = "has_matches"
)
```

> 改/删告警前先 `alert_list` 拿 id 与现状，跟用户确认再动；`alert_status` 看启停。

### 告警没响 ≠ 没问题：静默失效排查

真实教训：接口连续报错好几天，一条告警都没来——告警链路任何一环坏掉都是**静默的**。用户问「为什么没报警」时按序排查：

1. `alert_list` 看该规则的 `has_errors` / `last_run`：查询自身报错、或 `last_run` 长期停跳，规则等于不存在；
2. 规则是否 `active`（`alert_status`）、channel 是否还挂在规则上——外部凭证轮换、账号/成员变更都可能悄悄打断 webhook 送达；
3. query 口径是否覆盖这类错误（典型漏：报错走 4xx / 应用层日志，规则只盯 5xx span）；
4. **用出事窗口回放**：把规则 query 加上事发的 `start_timestamp/end_timestamp` 手动 `query_run`，理应命中——不命中就是口径问题，命中了则问题在 2/3 环。

**新建/补齐告警后必须双向验证，不许「配完即信」**：正向——用历史出事窗口回放 query 确认能命中；反向——用**正常时段窗口**回放确认平时不命中。「配上即报且每窗口重复报」不是灵敏，是口径把常态当异常、或 `notify_when` 选错（见上方设计要点），先修语义再定阈值精确值。channel 送达有条件就人为触发一次核实。周期巡检（/loop 或每日定时）时顺带体检全部规则的 `has_errors` 与 `last_run` 是否停跳——**告警系统本身也要被监控**。

### 临时告警要有回收生命周期，别沉淀成僵尸规则

为验证一次上线（如「某修复上线后观察双发指纹是否复发」）临时建的观测告警，名字带 `[临时]` 前缀、`description` 里写清**建立目的 + 预期观察窗口 + 达成什么条件就删**。观察期一过就 `alert_delete` 收掉：临时规则长期挂着会在巡检体检里跟正式规则混在一起，误报还占注意力。回放这类临时告警时注意区分「修复前已持久化的旧数据回放命中」和「修复后新增命中」——前者是历史残留不代表修复失效，query 里要能把两者分开（如带上时间/checkpoint 维度），否则会把历史误当复发。

### 「让告警别再刷屏」的正确动作分诊

用户说「这个告警一直报，怎么让它报一次就停 / 沉默一段时间」，先分清诉求再动手，别一律去调阈值：

- **配上就每窗口重复报** → 是 `notify_when` 选错（状态类条件配成了 `has_matches`），改成 `starts_having_matches`（只报边沿）或 `has_matches_changed`（要同时感知恢复），见上方设计要点。这是「重复报」的头号病因。
- **确实是真问题、只是想暂时静音（如已知在修）** → 用 `alert_update(active=false)` 停掉、修复后再 `active=true` 恢复，而不是删规则或把阈值调到永不触发（后者会把规则变成静默失效的僵尸）。停用属于对告警的改动，先 `alert_list` 确认现状、跟用户说明再动。
- **常态波动被当异常** → 是阈值/口径问题，回 `diagnostics` 思路先查真实 series 再定阈值，别拍脑袋加余量。

## 巡检 + 看板 + 告警怎么配合

- **临时盯一件事**（如刚发布、跟一个 bug）→ `/loop` 巡检，灵活、带分析、用完即停。
- **长期固化的健康面**→ 做成 `dashboard-panels.md` 看板，人随时看。
- **要被动收到通知**（不盯屏）→ Logfire alert，webhook 到飞书。
- 三者常一起上：巡检发现新问题 → 建看板长期观察 → 加 alert 兜底通知。

## 下一步

- 巡检/告警命中了 → `rca-trace.md` 下钻根因。
- 不确定值不值得专门修 → `quant-decision.md`。
