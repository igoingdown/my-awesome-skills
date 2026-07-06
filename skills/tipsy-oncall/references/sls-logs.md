# SLS 日志查询 recipe(tipsy-backend 主日志通道)

这份文档在你需要查 Go 主服务(tipsy-backend / chat / api 网关等)的**运行日志**时使用。所有查询走 aliyun-sls MCP,不用自己拼签名;通道选定在这里,查询模板、字段过滤、时区/limit 等常见坑也一并列在这里。跟 memory 服务的 SigNoz 通道互补,和 SLS 的 mempoint 静默特性配合看(见「常见静默陷阱」)。查任何 backend 报错、接口异常、请求下钻,默认先来这份文档。

## 环境映射

先按环境选定 project/logStore/regionId,写死的实例名:

| 环境 | project | logStore | regionId |
|------|---------|----------|----------|
| 线上 prod | `k8s-log-cdabe95251a0843e983951d48046d1b21` | `tipsy-chat` | `us-east-1` |
| 测试 test | `k8s-log-cbcdd4ec548224346a094bd067f3ade17` | `lightspeed-hk` | `cn-hongkong` |

鉴权走 `$ALIYUN_ACCESS_KEY_ID` / `$ALIYUN_ACCESS_KEY_SECRET`,MCP 已自动装配,不用在 query 里传,**也永远别把 AK/SK 写进 prompt 或落盘**。

## 常用 MCP 工具

- `sls_execute_sql`:标准 SLS SQL(select ... from log),适合聚合、group by、count。
- `sls_execute_spl`:SPL(Search Processing Language),链式管道 `| where ... | stats ...`,复杂逻辑更省事。
- `sls_log_explore`:交互式探索,输出面板 URL,首次摸盘用;定位后再切 SQL/SPL 精确查。
- `sls_log_compare`:对比两个时间窗口(如上线前后),用于回归 / 异常放大验证。
- `sls_list_logstores`:忘了 logstore 名字时用。

## 查询语法要点

`query` 关键词用 **AND / OR / NOT** 连接,支持 SPL 与 SLS SQL 两种方言;`from_time` / `to_time` 支持相对时间字面量:`"now-30m"`、`"now-1h"`、`"now-24h"`,精细到分钟即可。

举例(线上,近 30 分钟某 trace 的错误):

```
project=k8s-log-cdabe95251a0843e983951d48046d1b21
logStore=tipsy-chat
regionId=us-east-1
query=trace_id:"7f3a..." AND level:ERROR
from_time=now-30m
to_time=now
limit=200
reverse=true
```

## 常用过滤字段

- `__tag__:_image_name_`:按容器镜像 tag 过滤 pod,定位到具体一次发版。
- `level:ERROR` / `level:WARN`:分级过滤。
- `trace_id` / `session_id` / `user_id`:业务侧下钻主键,后端一般会打进日志上下文。
- `msg`:纯文本子串,建议加双引号防被拆词。

## 时区与时间坑

Pod 内业务日志时间戳很多是 **UTC**(k8s 容器默认),但 `__time__` 是**采集时间(北京时间)**。写查询时以 `__time__` 为准;读结果时留意业务时间字段和采集时间可能差 8 小时,别把 UTC 的 12:00 直接当北京时间报出来。

## 常见坑

1. **limit 默认 100,超过 1000 后端会明显变慢或截断**,大区间建议用 count/group 聚合替代拉明细。
2. **时间窗超过 24 小时会被 sample**,拿到的不是全量,做精确 count 会偏。要么缩窗,要么用 `sls_log_compare` / 聚合查询。
3. **`reverse=true` 才是按 `__time__` 倒序**(最新在前);默认正序,首屏往往看到最老的一条,容易误判「没有新错」。
4. **mempoint 成功路径 backend 静默无日志** —— SLS 里查不到 ingest 成功记录 ≠ 没入库。要验证入库应直连 memory 服务的 `$TIPSY_MEMORY_URL_PROD` 或走 PG(见 memory-postgres.md)。

## 从 MetaMCP 中转版迁移

历史脚本 / prompt 里可能会看到 `mcp__tipsy-mcp__aluiyun-sls-mcp__*` 这种命名,是 MetaMCP 中转的旧接口,已切到原生 `mcp__aliyun-sls__*`。**参数结构一致**,只需要改工具名,`project` / `logStore` / `regionId` / `query` / `from_time` / `to_time` / `limit` / `reverse` 全部保留,直接搜替换即可。

## 排障案例

**接口 500 按 trace_id 下钻**
现象:前端上报某聊天接口偶发 500,拿到 `trace_id=7f3a...`,时间为北京时间 11:20 前后。
通道:aliyun-sls MCP,线上 project/logStore/regionId 三件套。
查询:`sls_execute_sql`,`query="trace_id:\"7f3a...\" AND level:ERROR"`,`from_time="now-1h"`,`reverse=true`,`limit=50`。
结论:命中 3 条 ERROR,栈定位到调用 memory `/v1/memory/retrieve` 超时;进一步用 SigNoz 看 memory 服务确认是下游依赖抖动,不是 backend 逻辑 bug。

## 下一步 / 相关

- `references/signoz.md`:memory 服务的日志 / trace 走 SigNoz,不在 SLS。
- `references/memory-direct.md`:mempoint 入库验证走直连 memory + PG,别只看 SLS。
- `references/prometheus.md`:错误率 / QPS 类量化查询走 PromQL,不用 SLS 聚合。