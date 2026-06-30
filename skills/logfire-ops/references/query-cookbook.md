# query-cookbook：用 query_run 查 Logfire

`query_run` 自带 schema 参考，直接用即可，不必先调 `token_info` / `project_list`。只在需要完整字段定义时调一次 `query_schema_reference`（每会话最多一次）。

## records 表常用字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `start_timestamp` | TIMESTAMPTZ | 开始时间（高效过滤，优先用它卡时间窗） |
| `end_timestamp` | TIMESTAMPTZ | 结束时间 |
| `duration` | DOUBLE | span 持续时间（**秒**） |
| `span_name` | TEXT | span 名称（高效过滤） |
| `message` | TEXT | 日志/ span 消息 |
| `service_name` | TEXT | 服务名（高效过滤） |
| `deployment_environment` | TEXT | 部署环境：`prod` / `dev` / `test` |
| `level` | SMALLINT | 日志级别：`9`=INFO `13`=WARN `17`=ERROR（注意 ERROR 是 17 不是别的） |
| `trace_id` | TEXT | 链路追踪 ID（高效过滤） |
| `span_id` / `parent_span_id` | TEXT | span 层级关系 |
| `kind` | TEXT | `span`（请求）或 `log`（日志） |
| `attributes` | JSON | 结构化属性（用 `->>` 访问） |
| `is_exception` | BOOLEAN | 是否异常 |
| `exception_type` / `exception_message` | TEXT | 异常类型/消息（**常为 null，别只靠它**，见铁律 2） |
| `http_method` / `http_route` | TEXT | HTTP 请求信息（高效过滤） |
| `http_response_status_code` | INT | HTTP 状态码 |

## 三条查询铁律

1. **`->>` 精确过滤，禁止 `attributes::text ILIKE '%id%'`**（全表扫，极慢）。`ILIKE` 只对 `span_name` / `message` 做关键词模糊搜。
2. **错误详情看应用层日志，不看顶层 `exception_*` 列**。4xx/5xx 的 `detail` 往往不在 span，而在 `message` / `attributes->>'error'` / `attributes->>'exception'`。
3. **永远加 `LIMIT`**（聚合查询也要）；时间窗用 `start_timestamp/end_timestamp` 工具参数控制（最大 14 天，默认 30 分钟）。要长回溯就显式传 `start_timestamp`。

## tipsy 项目常用 attributes 字段

| 字段 | 说明 |
|---|---|
| `attributes->>'project_id'` | 项目 UUID（字符串）。注意是内部 UUID，不是业务 biz_id |
| `attributes->>'run_id'` | chat run ID |
| `attributes->>'session_id'` | sandbox session UUID |
| `attributes->>'sandbox_id'` | E2B sandbox ID |
| `attributes->>'model_id'` / `attributes->>'model_name'` | 所用模型 |
| `attributes->>'provider'` | 模型提供商 |
| `attributes->>'error'` | 应用层错误字符串（排障主力字段） |
| `attributes->>'exception'` | 完整 traceback（有 `logger.exception` 时优先捞它，别读 message 猜） |
| `(attributes->>'duration_ms')::DOUBLE` | 耗时（毫秒，数值） |

## 配方

### 按环境 + 时间扫最近记录

```sql
SELECT start_timestamp, span_name, message, http_route, http_response_status_code
FROM records
WHERE deployment_environment = 'prod'
ORDER BY start_timestamp DESC
LIMIT 50
```

### span_name / message 关键词模糊搜（ILIKE 只在这用）

```sql
SELECT start_timestamp, span_name, message, attributes
FROM records
WHERE span_name ILIKE '%chat%'
  AND deployment_environment = 'prod'
ORDER BY start_timestamp DESC
LIMIT 20
```

### 聚合统计（按 span / 状态码分布）

```sql
SELECT span_name, kind, count(*) AS cnt
FROM records
WHERE deployment_environment = 'prod'
GROUP BY span_name, kind
ORDER BY cnt DESC
LIMIT 30
```

### 按 trace_id 追全链路（根因排障第一步）

```sql
SELECT start_timestamp, span_name, message, span_id, parent_span_id, kind, duration,
       attributes->>'error' AS err
FROM records
WHERE trace_id = '019ef9b3...'
ORDER BY start_timestamp ASC
LIMIT 200
```

### 按已知 ID 精确过滤（project / run / session）

```sql
SELECT start_timestamp, span_name, message, attributes
FROM records
WHERE attributes->>'project_id' = '4b532c10-a63f-4473-9162-1e3472b9f389'
ORDER BY start_timestamp DESC
LIMIT 50
```

### 找 5xx / 异常并捞应用层错误

```sql
SELECT start_timestamp, http_route, http_response_status_code,
       message, attributes->>'error' AS err, trace_id
FROM records
WHERE deployment_environment = 'prod'
  AND (http_response_status_code >= 500 OR is_exception)
ORDER BY start_timestamp DESC
LIMIT 100
```

### 捞完整 traceback（有 logger.exception 时）

```sql
SELECT start_timestamp, message, attributes->>'exception' AS tb, trace_id
FROM records
WHERE message = 'sandbox.wake.failed'
  AND deployment_environment = 'prod'
ORDER BY start_timestamp DESC
LIMIT 20
```

### 时序分桶（看趋势，给量化分析用）

```sql
SELECT date_trunc('hour', start_timestamp) AS h, count(*) AS cnt
FROM records
WHERE deployment_environment = 'prod'
  AND http_response_status_code >= 500
GROUP BY h
ORDER BY h
LIMIT 200
```

### 时延分位数（P95/P99）

```sql
SELECT count(*) AS n,
       approx_percentile_cont(CAST(attributes->>'duration_ms' AS DOUBLE), 0.95) AS p95_ms,
       approx_percentile_cont(CAST(attributes->>'duration_ms' AS DOUBLE), 0.99) AS p99_ms
FROM records
WHERE message = 'chat.sunrise.success'
  AND deployment_environment = 'prod'
LIMIT 1
```

## 易踩的坑

- **level=17 才是 ERROR**：只盯 error 级会漏掉很多 level 9（INFO）里埋的失败信号（很多业务失败是 INFO/WARN 级）。排障别只 `WHERE level=17`。
- **`duration` 是秒，`attributes->>'duration_ms'` 是毫秒**，别混。
- **子 span 可能比父 span 结束得晚**（后台任务在 HTTP 响应后继续跑），按 trace 看时序要留意。
- **project 参数**：token 未绑定项目时必传 `project: "tipsy"`。
- **biz_id ≠ project_id**：日志里的 `project_id` 是内部 UUID，用户给的业务 ID 可能要先在 DB 映射。

## 下一步

- 查出来想长期盯 → `dashboard-panels.md` 做成 panel。
- 查出来要定根因 → `rca-trace.md`。
- 查出来要判断值不值得修 → `quant-decision.md`。
