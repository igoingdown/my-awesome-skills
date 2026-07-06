# Metric Pitfalls —— 写 PromQL 前必读

这份文档汇总了 tipsy-backend 五大最容易踩雷的指标陷阱。在你写任何 PromQL 查询、任何 Grafana 告警规则、任何看板面板之前，务必先扫一遍；口头查询也算——只要你会把查询结果当作决策依据，就要过一遍这五条。触发场景：调 `cms_execute_promql`、写告警阈值、看板 panel query、值班时被问"某某指标为什么长这样"。

铁律 4「比率必 clamp_max 封顶」、铁律 6「多副本 Gauge 必聚合」、铁律 7「http vs gin 时延指标覆盖差异」在这里展开。

## 1. 比率必封顶 clamp_max，低流量维度加门槛

错误示范：

```promql
sum by (route)(rate(tipsy_http_requests_total{status="500"}[5m]))
  / sum by (route)(rate(tipsy_http_requests_total[5m]))
```

正确示范：

```promql
clamp_max(
  sum by (route)(rate(tipsy_http_requests_total{status="500"}[5m]))
    / (sum by (route)(rate(tipsy_http_requests_total[5m])) + 1e-7),
  1
)
and on (route) (sum by (route)(rate(tipsy_http_requests_total[5m])) > 0.05)
```

为什么错：Prometheus 分子分母都可能为 0；很多人下意识用 `+ 1e-7` 兜底分母，但一旦分子有 1 个错误、分母同时 ≈ 0，算出的比率就是 `1 / 1e-7 = 1e7` 级别的天文数字，告警瞬间炸。必须 `clamp_max(..., 1)` 把上限锁死；再用 `and on(...)(总量 > 阈值)` 把低流量维度门槛掉，避免"一天来 3 个请求错 1 个 = 33%"引发误报。宝石/订阅这类天然低频接口尤其要给门槛，否则夜间流量低谷全是虚警。

如果你在写告警，请转 grafana-as-code skill 并读它的 references/alerting.md。

## 2. HTTP 时延不是全路由覆盖：chat vs 非 chat 分家

错误示范：给订阅/支付/webhook 路由用 `tipsy_http_request_duration_seconds` 写 P99 告警。

正确示范：

- chat 路由（`/v1/chat/*`）：`tipsy_http_request_duration_seconds_bucket`
- 订阅/支付/webhook/其他 gin 路由：`gin_request_duration_seconds_bucket`（桶上限 10s）

为什么错：`tipsy_http_request_duration_seconds` 是聊天链路专用埋点，只覆盖 chat 路由。给非 chat 路由套上去，PromQL 永远返回空——Grafana 告警识别为 `noData`，规则**静默无保护**，Core Payment 出问题也不告警。写 Core Payment、订阅、webhook 告警前一定要先跑 `count(metric{route="..."})` 验证覆盖；此外 `gin_request_duration_seconds` 桶最上限是 10s，超过 10s 的慢请求全落 `+Inf` 桶，P99 会失真，需要用错误率或超时率作为补充信号。

如果你在写告警，请转 grafana-as-code skill 并读它的 references/alerting.md。

## 3. circuit_state 语义反直觉，多副本必聚合

错误示范：

```promql
tipsy_anthropic_circuit_state == 0
```

（以为"0 = 正常"——llmdoc 早期版本曾写反过。）

正确示范：

```promql
min by (provider, account_id) (tipsy_anthropic_circuit_state) == 0
```

为什么错：**1 = 可用，0 = 熔断中**。而且每个 pod 都会独立上报一份这个 Gauge，如果你不 `max by (provider, account_id)`（告警场景反过来用 `min by`——只要有一个 pod 报熔断就要告警），Grafana 面板会画出锯齿，告警会因为某个刚重启还没就绪的 pod 常态触发。相关的 `tipsy_anthropic_request_total` 的 `status` label 枚举是 `ok / fail / refusal`（不是 `error`／`success`），写筛选条件拼错会**静默返回空**——PromQL 不会报错，你以为一切正常，实际上根本没匹配到样本。

如果你在写告警，请转 grafana-as-code skill 并读它的 references/alerting.md。

## 4. runtime 指标必须按 pod 前缀或 app 标签过滤

错误示范：

```promql
go_goroutines
process_resident_memory_bytes
```

正确示范：

```promql
go_goroutines{kubernetes_pod_name=~"tipsy-chat-.*"}
pine_recall_latency_seconds{app="tipsy-recsys"}
```

为什么错：default namespace 下混跑 4 个服务——`tipsy-chat`、`tipsy-recsys`、`tipsy-subscription`、`tipsy-integration`。裸的 `go_goroutines / process_resident_memory_bytes / go_gc_duration_seconds` 是 Prometheus client 默认导出，**没有 app 标签**，四个服务的数据全糊在一起；不加 `kubernetes_pod_name=~"..."` 过滤，面板画出来是意义不明的叠加图。业务侧指标（如推荐 `pine_*`、支付上下文 `tipsy_paid_*`、宝石订阅相关计数）通常带 `app` label，用 `app="tipsy-recsys"` 更稳。写查询前先 `count by(app, kubernetes_pod_name)(指标)` 摸清楚归属，别拿混合数据下结论。

如果你在写告警，请转 grafana-as-code skill 并读它的 references/alerting.md。

## 5. paid_context_resolve 的 source=disabled 是入口伪值

错误示范：

```promql
sum(rate(tipsy_paid_context_resolve_total{source="disabled"}[5m]))
  / sum(rate(tipsy_paid_context_resolve_total[5m])) > 0.5
```

（以为"disabled 占比高 = 金额解析被大面积关闭 = 出事了"。）

正确示范：把根因诊断收敛到 `replace_sensitive_words` 入口：

```promql
sum by (source)(rate(tipsy_paid_context_resolve_total{entrypoint="replace_sensitive_words"}[5m]))
```

为什么错：`paid_context_resolve` 有两个入口——`score_check` 和 `replace_sensitive_words`。**`score_check` 入口的 source label 被写死为 `disabled / unknown`**，它不是真实解析路径，只是打点占位。按 `source="disabled"` 占比告警会常态触发（因为 score_check 本身流量就大），是标准的误报陷阱。真正判断金额解析根因、看解析源分布、追问"为什么这条消息里的付费触发词没被识别"，只能看 `entrypoint="replace_sensitive_words"` 这一路。

如果你在写告警，请转 grafana-as-code skill 并读它的 references/alerting.md。

## 下一步 / 相关

- `references/prometheus.md`：`mcp__aliyun-sls__cms_execute_promql` 的调用样板、tipsy 常用指标 label 集合、时间窗口/step 选择建议。
- `references/environments.md`：区分 prod/test 的 SLS project、MySQL/PG/Lindorm 实例名，防止串环境查错指标。
- `references/report-format.md`：五段报告如何把 PromQL 查询结果落成结论行，避免"贴一堆截图但没结论"。
- 写告警：转 `grafana-as-code` skill，走 DRY spec → generate → validate → push 全流程，不要手改 Grafana UI。