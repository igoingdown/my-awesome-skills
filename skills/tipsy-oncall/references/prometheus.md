# ARMS Prometheus 指标查询

这份文档解决"如何在值班时快速查 tipsy-backend 的运行时指标"这一件事。当告警群里报了错误率飙升、P99 变慢、副本 OOM 或熔断打开、你需要在真实数据上验证告警是不是假警之前，先读这里。写告警规则、调阈值、推看板不属于本 skill，那些操作走 grafana-as-code skill。

## 数据源与调用方式

tipsy-backend 的 Prometheus 指标全部落在阿里云 ARMS Prometheus，Grafana 只是可视化层，本 skill 不走 Grafana 直连。查询统一通过 `mcp__aliyun-sls__cms_execute_promql` 跑 PromQL，鉴权与 workspace 参考 secrets.sh 里的 `$ALIYUN_ACCESS_KEY_ID` / `$ALIYUN_ACCESS_KEY_SECRET` / `$ARMS_PROM_REGION` / `$ARMS_PROM_WORKSPACE`。只读默认，永远不写规则、不改 target。

## 必须记住的指标

- `tipsy_http_request_duration_seconds` — **只覆盖 chat 路由**（SSE 那一坨）。非 chat 路由（订阅、webhook、CMS）不在这里，走下一条。
- `gin_request_duration_seconds` — 覆盖除 chat 外的所有 HTTP 路由，桶最大到 10s，超过 10s 一律计入 `+Inf`，用来看长尾会失真。
- `tipsy_anthropic_circuit_state` — 熔断状态，**语义反直觉**：`1 = 可用`，`0 = 熔断打开`。做告警别写反。
- `tipsy_*_request_total{status="ok|fail|refusal"}` — 各外部依赖（anthropic、openai、amap 等）的请求计数。`refusal` 是被模型拒答，不是错误，算错误率时要按业务需要拆开。
- `go_goroutines`、`process_resident_memory_bytes` — Go 运行时指标。**必须加 `kubernetes_pod_name=~".*"` 过滤**，因为 default namespace 下同时跑了 4 个服务（backend、memory、offline、cms），不筛 pod 会把 4 个进程一起加起来。
- `paid_context_resolve_*` — 付费上下文解析根因指标。注意 `source="disabled"` 陷阱：功能关掉时会持续写 disabled，不是真正的失败，做告警要排除，详见 metric-pitfalls.md。

## PromQL 三条铁律

1. **比率永远 `clamp_max(..., 1)` 封顶**。counter reset 或 rate 时间窗错位会短暂拿到 >1 的比率，不封顶告警拉稀，口头查询同样封顶。
2. **多副本 Gauge 用 `sum by(...)` 或 `max by(...)` 收敛**。tipsy-backend 通常 3~6 副本，直接 raw 查会拿到多条曲线，做告警时优先 `max by(pod)`（看最差副本），做容量水位用 `sum by(service)`（看总体）。
3. **低流量维度用 `and on(...)` 门槛过滤**。比如按 route 做错误率，路由 QPS < 0.1 时数据没有统计意义，用 `and on(route) (sum by(route)(rate(...)) > 0.1)` 过滤掉。

## 常用查询模板

**chat 路由 P99 时延**（单位秒）：

```promql
histogram_quantile(0.99,
  sum by (le, route) (
    rate(tipsy_http_request_duration_seconds_bucket[5m])
  )
)
```

**非 chat 路由 P99**（10s 桶天花板问题记在心里）：

```promql
histogram_quantile(0.99,
  sum by (le, route) (rate(gin_request_duration_seconds_bucket[5m]))
)
```

**anthropic 错误率**（clamp 封顶 + 流量门槛）：

```promql
clamp_max(
  sum(rate(tipsy_anthropic_request_total{status="fail"}[5m]))
  /
  sum(rate(tipsy_anthropic_request_total[5m])),
  1
) and on() (sum(rate(tipsy_anthropic_request_total[5m])) > 0.1)
```

**熔断状态**（值 = 0 表示熔断打开）：

```promql
min by (service) (tipsy_anthropic_circuit_state)
```

**pod 内存 top**（记得筛 pod）：

```promql
max by (kubernetes_pod_name) (
  process_resident_memory_bytes{kubernetes_pod_name=~"tipsy-backend-.*"}
)
```

**pod 协程数**（同样筛 pod）：

```promql
max by (kubernetes_pod_name) (
  go_goroutines{kubernetes_pod_name=~"tipsy-backend-.*"}
)
```

## 与 grafana-as-code skill 的边界

本 skill **只读**。想加告警规则、改阈值、推看板、复用告警模板——切到 `grafana-as-code` skill，那边有 `deploy/grafana/` 的 spec→generate→validate→push 工作流。本文档里的 PromQL 是查询语句，不是告警表达式，直接复制粘贴到 alertmanager 会缺 `for`、缺 label、缺 clamp_max，别偷懒。

## 真实排障案例

**告警说 chat P99 5 分钟均值 30s，是不是真的？**
通道：`cms_execute_promql`。
查询：`histogram_quantile(0.99, sum by (le, route)(rate(tipsy_http_request_duration_seconds_bucket[5m])))`，range 拉过去 30 分钟。
结论：曲线在 3s 附近抖动，个别点冲到 30s 是因为 anthropic 长响应流式，按 route 拆开发现只 `/api/v1/chat/stream` 一条路由有毛刺，占总量 <5%，属于长尾波动不是普遍变慢——告警是 SLI 定义问题，不是故障。

## 下一步 / 相关

- 指标本身的坑（熔断反语义、http vs gin 覆盖差异、paid_context_resolve disabled 陷阱、多副本 Gauge 加总）— `references/metric-pitfalls.md`
- 想加告警规则、改阈值、推看板 — `grafana-as-code` skill
- SLS 行日志（不是指标）— `references/sls-logs.md`
- memory / mempoint 指标（走 signoz，不是 ARMS）— `references/signoz.md`