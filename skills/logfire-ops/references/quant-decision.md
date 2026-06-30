# quant-decision：用数据判断「值不值得修」

定位了一个问题后，别急着修。先用历史数据量化它的**频率 × 影响面 × 趋势 × 严重度**，给出优先级建议。目标是把「感觉是个 bug」变成「7 天 N 次、影响 M 个项目、趋势平稳、用户无硬失败 → 低优先」这种可决策的结论。

## 四个维度

### 1. 频率（多久发生一次）

```sql
-- 近 14 天该问题的总次数 + 按天分布
SELECT date_trunc('day', start_timestamp) AS day, count(*) AS cnt
FROM records
WHERE deployment_environment='prod'
  AND message = 'chat.provider_error'           -- 换成你的问题签名
  AND attributes->>'error' ILIKE '%no available channel%'
GROUP BY day
ORDER BY day
LIMIT 30
```

判读：是「7 天 1 次极罕见」还是「每天稳定 N 次」还是「突然爆发」。

### 2. 影响面（波及多少独立实体 / 是否集中在个别）

```sql
-- 波及多少独立 project / session，是否高度集中（个别惯犯 vs 普遍）
SELECT count(*) AS total_events,
       count(DISTINCT attributes->>'project_id') AS distinct_projects,
       count(DISTINCT attributes->>'session_id') AS distinct_sessions
FROM records
WHERE deployment_environment='prod'
  AND message = 'chat.provider_error'
```

```sql
-- Top 受影响实体：是否 90% 集中在一个 session（→ 个案，可能非系统性）
SELECT attributes->>'session_id' AS session_id, count(*) AS cnt
FROM records
WHERE deployment_environment='prod' AND message='chat.provider_error'
GROUP BY session_id
ORDER BY cnt DESC
LIMIT 20
```

判读：**1000 次但全在 1 个 session** vs **100 次散在 80 个项目**——后者系统性强、优先级更高。「distinct≥2 且分散」往往才是系统性问题。

### 3. 严重度（用户是否硬失败）

- 用户**硬失败**（请求直接 4xx/5xx、对话中断）→ 高严重度。
- **静默降级**（fallback 到确定性结果，用户无感）→ 低严重度，即使频率高也可缓。
- 烧钱/烧算力（如空转十几分钟）→ 即使用户无感也值得修（成本维度）。

```sql
-- 占比：这个问题占该接口总请求的多大比例（算 SLI 影响）
SELECT
  count(*) FILTER (WHERE http_response_status_code >= 500) AS errors,
  count(*) AS total,
  round(100.0 * count(*) FILTER (WHERE http_response_status_code >= 500) / count(*), 3) AS err_pct
FROM records
WHERE deployment_environment='prod' AND http_route = '/api/sdk/v1/respond'
LIMIT 1
```

### 4. 趋势（在变好还是变坏）

```sql
-- 按天看是否上升趋势（决定「现在修 vs 观察」）
SELECT date_trunc('day', start_timestamp) AS day, count(*) AS cnt
FROM records
WHERE deployment_environment='prod' AND is_exception
  AND span_name LIKE 'chat %'
GROUP BY day ORDER BY day LIMIT 30
```

判读：平稳的低频问题可「观察+建告警兜底」；上升趋势的要尽快处理；新出现（首次）的要警惕。

## 决策框架

综合四维给一个结论，落到下面四档之一：

| 档 | 条件 | 建议 |
|---|---|---|
| **立即修** | 用户硬失败 + （频率高 或 上升趋势 或 影响面广） | 排 P0/P1，给修复方案 |
| **排期修** | 用户硬失败但低频平稳，或无硬失败但烧钱/趋势上升 | 进 backlog，建 panel/alert 盯着 |
| **观察** | 低频 + 良性/自愈 + 平稳 + 影响集中 | 不动代码，建 alert 兜底，写进 Observation Gap 持续观察基线 |
| **不修（结案）** | 个案 / 测试数据 / 探针噪声 / 规则按设计工作 | 说清为什么不是 bug，留证据备查 |

## 写结论的规范

每个判断都带数字和证据，例如：

> 近 14 天 N 次，散在 M 个独立 project（非个别惯犯），全部 fallback 到确定性截断、用户无硬失败，趋势平稳。命中既有告警阈值属正常波动。**结论：真实但良性，建议「观察」——保留 alert 兜底，不专门修。**

避免：
- 把「瞬态自愈」当事故拉高优先级。
- 把「个别 session 刷出来的高计数」当系统性问题。
- 没算影响面/趋势就拍脑袋说「得修」。
- 把「测试数据/探针噪声」当真实用户问题。

## 易踩的坑

- **biz_id ≠ project_id**：算 distinct 项目时用日志里的内部 `project_id`；要回报给业务方再去 DB 映射 biz_id。
- **别只数 ERROR 级**：很多失败是 INFO/WARN 级或 200 流内，只 `WHERE level=17` 会严重低估频率。
- **窗口一致**：算频率/影响面/趋势用同一时间窗，别一个 7 天一个 30 天混着比。
- **观测盲区先承认**：detail 没进 span 时，先说「需补打点才能量化」，别用不全的数据下硬结论。

## 下一步

- 判「立即修/排期修」→ 进入修复（接 `rca-trace.md` 的方案）。
- 判「观察」→ `monitoring-loop.md` 建 alert + `dashboard-panels.md` 建 panel 盯基线。
