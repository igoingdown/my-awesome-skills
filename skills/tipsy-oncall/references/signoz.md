# SigNoz —— tipsy-memory 服务的 APM / trace / log

这份文档解决"tipsy-memory 服务的记忆写入 / 检索 / 摘要为什么慢、为什么错、为什么没入库"这一类问题。当值班过程中定位到根因落在 memory 服务(Python 侧,而非 tipsy-backend Go 侧),或需要沿单次 ingest / retrieve 的 trace 下钻全链路时,读这份。tipsy-backend Go 主链路的日志不在这里,请转 references/aliyun-sls.md。

## 1. 服务映射与环境

- 服务名(`service.name`)固定为 `tipsy-memory-demo`。**注意 `-demo` 后缀是线上生产名,不是测试环境**,历史遗留命名,不要因为 demo 字样就跳过或误判为 dev。
- 测试环境的 tipsy-memory 走同一个 SigNoz 实例,通常通过 `deployment.environment` 或 pod 标签区分。不确定时先用 `signoz_get_field_keys` 列一遍现网可用标签,别凭记忆猜。
- 直连服务 base URL 是 `$TIPSY_MEMORY_URL_PROD` / `$TIPSY_MEMORY_URL_TEST`,curl 无鉴权。查证配对时建议手工带 `-H 'x-request-id: ...'` 打点,便于回到 SigNoz 里按 request-id 反查 trace。

## 2. 核心 MCP 工具速查

- `signoz_search_logs`:按时间窗 + 关键字捞日志,支持 `searchText` 全文与结构化 `query`。默认先用 searchText,命中太多再收敛。
- `signoz_search_traces`:按 service / operation / duration / 状态码检索 trace 列表,拿 traceID。
- `signoz_get_trace_details`:输入单个 traceID,返回该请求全链路 span 树,含 span 属性、时长、异常。**这是 memory 侧下钻的主武器**。
- `signoz_query_metrics`:跑 PromQL(SigNoz 自带),查 APM 指标 —— P50 / P95 / P99 延迟、错误率、QPS。
- `signoz_get_field_keys` / `signoz_get_field_values`:字段发现工具。不知道日志或 span 里可过滤的 key 时先跑这个,避免瞎猜字段名。
- `signoz_get_service_top_operations`:列出某服务近期最热的 operation,按调用量 / 时延排序,找性能拐点用。
- `signoz_list_metrics`:列出可用指标名,套 PromQL 模板前先确认指标存在。

## 3. 关键 span 名 / 日志关键词

memory 服务侧的高信噪比关键词,写查询时优先套:

- `Processing ingest`:一次 ingest 请求进入处理时的 span,通常带 `session_id` / `user_id` / `character_id` 属性。
- `ingest resolved`:ingest 结束标记,附最终写入的 mempoint 数量,失败会在同一 traceID 里带异常 span。
- `dedup key hit`:命中去重、被拦截未落库,mempoint "为什么没入库"的第一嫌疑(见 SKILL.md mempoint 语义章节)。
- `retrieve`:检索链路 span,通常伴随 top-k / recall 相关属性。
- `summary`:摘要生成链路,慢查基本都聚集在这个 span 下,下游 LLM 超时会直接反映在 span 时长上。

## 4. 日志查询语法

- 全文搜索:`searchText: "ingest resolved"`,配合时间窗 + `service.name` 过滤。
- 结构化过滤:`query` 里传 `service.name = 'tipsy-memory-demo' AND body CONTAINS 'dedup key hit'`,可叠加 `attributes.session_id = '...'`。
- 时间窗:排障默认拉最近 1 小时;要对比昨天同时段,把 start / end 分两次查再对比,别在同一次查询里塞两个窗。
- 命中太多时先用 `signoz_get_field_values` 查 `attributes.session_id` 或 `attributes.user_id` 的分布,再精确回捞,不要盲扫全量。

## 5. SigNoz 与 aliyun-sls 的分工(不要混)

- **tipsy-memory(Python 服务)→ SigNoz**:ingest / retrieve / summary / delete 的全部 span 与 print,mempoint 相关的根因几乎都在这里。
- **tipsy-backend(Go 主链路)→ aliyun-sls**:HTTP / SSE / RabbitMQ 死代码 / 定时器 / 业务日志。SLS 里搜 "mempoint" 是静默的(见 SKILL.md 铁律 8),tipsy-backend 只做 HTTP 转发,不打 mempoint 结构化日志。
- 一次链路排障常见路径:aliyun-sls 里从用户请求捞到 `x-request-id` → 拿去 SigNoz `signoz_search_logs` 反查 → 命中 traceID → `signoz_get_trace_details` 看全链路。

## 6. APM 指标(P99 / 错误率 / 吞吐)

用 `signoz_query_metrics` 走 PromQL,常用模板:

- P99 延迟:`histogram_quantile(0.99, sum by (le, operation) (rate(signoz_latency_bucket{service_name="tipsy-memory-demo"}[5m])))`
- 错误率:`sum(rate(signoz_calls_total{service_name="tipsy-memory-demo",status_code="STATUS_CODE_ERROR"}[5m])) / sum(rate(signoz_calls_total{service_name="tipsy-memory-demo"}[5m]))`(比率务必按 SKILL.md 铁律用 `clamp_max(..., 1)` 封顶)
- 吞吐:`sum by (operation) (rate(signoz_calls_total{service_name="tipsy-memory-demo"}[5m]))`

指标名以现网 SigNoz 版本为准,先用 `signoz_list_metrics` 确认再套模板,别硬编码。

## 7. 常用查询模板

- **按 session_id 拉整条 ingest 链**:`searchText` 直接用 session_id 值,时间窗覆盖前后 10 分钟,拿一批 log 再抽一条 traceID 走 `signoz_get_trace_details`。
- **失败 ingest 排序**:`signoz_search_traces` 里加 `status.code = ERROR` + `service.name = 'tipsy-memory-demo'`,按 timestamp desc,快速看最近的失败样本。
- **慢 ingest Top N**:`signoz_search_traces` 按 duration desc,operation 限定为 ingest 相关 span,快速找到毛刺请求。
- **热点操作**:`signoz_get_service_top_operations` 直接列表,配合 P99 判断慢是慢在 ingest、retrieve 还是 summary。

## 8. 排障案例

**某 session ingest 慢,通过 SigNoz 找 trace**:
- 现象:用户反馈某 session 的记忆一直没入库,ingest 接口返回 200 但下游查不到 mempoint。
- 通道:SigNoz(memory 服务在 SigNoz,不在 SLS,别搜 SLS 白费功夫)。
- 查询:`signoz_search_logs` 用 session_id 全文搜命中 `Processing ingest` → 抽 traceID → `signoz_get_trace_details`。
- 结论:`summary` span 耗时 >30s 且下游 LLM 超时,ingest 本身没错,是摘要链路模型侧超时,回到 tipsy-backend 侧确认是否要缩短 batchTurns 或加退让重试。

## 9. 下一步 / 相关

- tipsy-backend Go 主链路日志 → references/aliyun-sls.md
- 记忆表结构 / mempoint 落库验证 → references/pg-memory.md
- 直连 memory HTTP 接口验证(ingest / retrieve / summary / delete)→ references/memory-http.md
- MySQL / Lindorm 相关 → references/mysql.md、references/lindorm.md
- Grafana 阈值 / 告警校准 → 转 grafana-as-code skill