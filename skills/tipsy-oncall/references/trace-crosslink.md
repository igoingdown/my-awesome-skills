# trace-crosslink.md —— 一个 trace_id 三路串联

tipsy 后端最难查的一类问题不是 backend 自己挂,而是链路"一层套一层":backend 返回失败 → 调 memory 服务失败 → memory 又调 embedding / 上游模型失败,每层的日志都只说"upstream error"。这种情况必须拿到一个 trace_id 把三个可观测通道 —— SLS(backend Go)、SigNoz(memory Py)、Logfire(studio)—— 串起来才能定位根因。这份文档告诉你:trace_id 从哪拿、三路怎么查、时间怎么对齐、常见坑在哪。

**什么时候读**:用户报障"接口 500 / 超时",backend 日志只有一句 upstream_error 没有堆栈,需要往下游追;或者你已经拿到一个 trace_id,想快速把三路日志摊平画时间线。

## §1 拿到 trace_id 的三条路

- 用户主动给:前端错误提示里的 `X-Request-Id` / `trace_id` header 是最快的入口。让用户在浏览器 DevTools → Network 里复制失败请求的响应 header,或者从 SDK 报错弹窗里抠。
- SLS 反查:只有 uid + 大致时间窗时,用 `mcp__aliyun-sls__sls_execute_sql` 加 uid 和路径过滤,回捞出 trace_id 字段。
- SigNoz UI 抓:如果只知道是 memory 服务出错,进 SigNoz Traces 面板按 service 过滤,拿慢/错的 trace ID。

拿到之后不要立刻查三路,先记一下这次 trace_id 是"backend 发起的"还是"memory 内部生成的"—— 服务边界可能被重写(见 §5)。

## §2 三路查询

**SLS(tipsy-backend Go 侧)**。project / logStore 按环境切:

- 线上:project=`$SLS_PROD_PROJECT`,logStore=`$SLS_PROD_LOGSTORE`,region=`us-east-1`
- 测试:project=`$SLS_TEST_PROJECT`,logStore=`$SLS_TEST_LOGSTORE`,region=`cn-hongkong`

```
mcp__aliyun-sls__sls_execute_sql
  project=$SLS_PROD_PROJECT
  logStore=$SLS_PROD_LOGSTORE
  query="trace_id: 'xxx' | SELECT __time__, level, msg, request_path, latency_ms FROM log ORDER BY __time__"
```

SLS 里 trace_id 字段名有历史遗留(`traceID` / `x_request_id`),先用 `sls_execute_spl` 抓一条样本确认字段名再套模板,别硬编码。

**SigNoz(tipsy-memory Py 侧)**。memory 服务上报 OTel 到 SigNoz:

- 一步到位拉全链路:`mcp__signoz__signoz_get_trace_details` 传 trace_id,直接拿到 span 树 + 每个 span 的 latency + attributes。
- 只关心日志:`mcp__signoz__signoz_search_logs` filter 用 `trace_id='xxx'`。

如果 memory 侧的 trace_id 和 backend 对不上,看每个 span 的 `parent_span_id` 反查父级 span,通常能顺藤摸回 backend 的 request id。

**Logfire(tipsy-studio 侧)**。studio 走独立 Python 仓的 Logfire,详细语法请转 `logfire-ops` skill。核心是 `mcp__logfire__query_run` 查 records 表:

```
mcp__logfire__query_run
  sql="SELECT start_timestamp, level, message, attributes FROM records WHERE trace_id='xxx' ORDER BY start_timestamp"
```

## §3 时间对齐 —— 一切归 UTC

三路时间戳的时区 / 精度都不一样,画时间线前必须统一到 UTC(SKILL.md §1 铁律 3):

- SLS `__time__` 是 UTC 秒(int),但控制台会按浏览器时区展示,肉眼比对时容易差 8 小时;走 API 拿到的就是 UTC 秒,不会踩坑。
- SigNoz timestamp 是 UTC 纳秒。
- Logfire `start_timestamp` 是 UTC 微秒。
- PG `created_at`、MySQL `created_at` 一律 UTC。

**先把 trace_id 出现的最早时间点 t0 统一转成 UTC ISO8601,再对三路各拉 `[t0 - 30s, t0 + 5min]` 窗口。** 时间窗过小会漏掉重试和异步落库,详见 §5。

## §4 一键三路脚本

`scripts/trace-crosslink.sh {trace_id} {env}`(env = `prod` / `test`)并行发起三路查询,统一转 UTC 输出到 stdout。用法:

```
bash scripts/trace-crosslink.sh 7b3f... prod
```

脚本内部封装了 project / logStore 切换、时间戳归一化、SLS 字段名兼容。不建议手拼三条命令 —— 时区弄错一次就要重新对时间线,浪费值班时间。

## §5 常见坑

- **trace_id 被重写**。少数下游服务(尤其是历史遗留的 recsys、第三方 SDK)不透传上游 trace_id,自己 uuid 一份塞进日志。表现是 backend 里的 trace_id 在 memory 里查无此人。这种情况改看 `parent_span_id`,或者用 uid + 时间戳 ±5s 反查 memory 侧日志。
- **只查 backend 找不到**。如果 backend 只落了 `upstream error` 的一行,不要在 backend 死磕,直接用 uid + 大致时间去 SigNoz `signoz_search_logs` 捞 memory 同时间窗的 error 日志,通常能捞到真正的堆栈。
- **时间窗留余量**。三路的时钟同步可能有几百毫秒到几秒漂移(尤其跨 region:线上 SLS 在 us-east-1、memory 服务在 cn-hongkong),`±5 分钟` 余量是保险起见。
- **正常路径不带 trace_id**。tipsy-backend 有些历史代码只在 error 分支打 trace_id,正常路径的 access log 不带。查性能问题(不是错误)时可能查不到 trace,退化到用 uid + 时间窗 + endpoint 匹配。

## 排障案例

**聊天返回慢 → 定位到 embedding 上游限流**。用户反馈"发消息 15s 才回",拿到 `X-Request-Id 7b3f...`。SLS 查 backend 侧只有一行 `POST /chat/send latency=14980 downstream=memory`,没细节;转 `signoz_get_trace_details` 拉 memory span 树,发现 `embedding.encode` 单 span 13.2s,attributes 里 `provider=ark`;交叉一看当日 volcengine 侧对该 key 限流。根因确认:embedding 上游限流,backend / memory 逻辑无问题,推动切备用 provider。

## 下一步 / 相关

- 只查 memory 服务本身的日志 / trace:见 `references/signoz.md`
- 只查 studio 侧 Logfire 语法:转 `logfire-ops` skill
- 只查 backend Go 侧 SLS 查询模板与字段:见 `references/sls-logs.md`
- 铁律"UTC 一律 UTC"与环境隔离:见 SKILL.md §1