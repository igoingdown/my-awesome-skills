# rca-trace：按 trace 下钻根因 + 找方案

目标：从「一个报错/异常现象」追到**确定的根因**，再给出**修复方案**。核心方法论：捞全链路 → 读应用层错误 → 回代码验证 → 区分真问题/良性 → 给方案。

## 标准流程

### 1. 锚定一个代表性 trace

从告警/巡检/用户报障拿到入口标识（任一）：`trace_id` / `run_id` / `project_id` / `session_id` / 报错关键词。先定位一条最干净的代表性 trace：

```sql
-- 已知报错关键词，找最近几条，拿 trace_id
SELECT start_timestamp, trace_id, span_name, http_route, http_response_status_code,
       attributes->>'error' AS err
FROM records
WHERE deployment_environment='prod'
  AND (message ILIKE '%no available channel%' OR attributes->>'error' ILIKE '%no available channel%')
ORDER BY start_timestamp DESC
LIMIT 20
```

### 2. 拉整条 trace 的所有 span/log

```sql
SELECT start_timestamp, span_name, message, span_id, parent_span_id, kind, level,
       duration, http_response_status_code,
       attributes->>'error' AS err, attributes->>'exception' AS tb
FROM records
WHERE trace_id = '<上一步拿到的>'
ORDER BY start_timestamp ASC
LIMIT 300
```

看：哪个子 span 先失败、父子时序、HTTP 状态、应用层 `error`/`exception`。

### 3. 读应用层错误，别读 span message 猜（最关键的一步）

- **顶层 `exception_type`/`exception_message` 常为 null**——别只靠它判断有没有错。
- 真正的错误详情在 `message`、`attributes->>'error'`、`attributes->>'exception'`（完整 traceback）。
- **HTTP message 可能是「次生异常」掩盖了真因**。例：wake 503 的 message 显示 `greenlet_spawn`，但那是 rollback 后惰性 IO 触发的次生异常，真因（`no healthy upstream`）藏在 `sandbox.wake.failed` 的完整 traceback 里。**有 `logger.exception` 就先捞 `attributes->>'exception'` 看 traceback，不要读 message 编故事。**
- **SSE/流式端点的失败裹在 HTTP 200 里**——别因为状态码 200 就判定成功，要看流内的应用层日志。

### 4. 回代码验证假设（不要停在日志层）

日志能告诉你「哪里炸了」，但根因常要读代码确认。把日志里的 `span_name` / `message` / 文件行号当线索，去仓库 grep：

- 这个错误字符串/日志是在哪段代码发出的？
- 触发它的前置条件是什么？是边界情况还是必现？
- 是平台 bug 还是上游/配置问题？

> 教训：只读日志推断会翻车。例如「i18n 翻译没触发」一度归因为「镜像缓存旧」，实则读代码才发现 gate 判错了变量（死代码恒 False）。**能读代码确认的，不要靠日志猜。**

### 5. 区分三态：真问题 / 良性自愈 / 观测盲区

- **真问题**：确定性复现、用户可感知受损、不自愈 → 给方案、定优先级（接 `quant-decision.md`）。
- **良性**：瞬态、自愈、规则按设计工作（如偶发 timeout 降级到确定性截断、用户无硬失败）→ 说清「真实但良性，无需改代码」，别当事故。
- **观测盲区**：现象可疑但 telemetry 不足以定论（如 400 的 detail 没进 span）→ 明确说「需要补打点 / 读 DB / 读代码」，别强行下结论。先**承认不知道**，再说怎么补证据。

### 6. 给方案

- 根因 + 证据（trace_id、计数、代码 file:line）。
- 修复方向（可多个，标注 ROI / 风险）。
- 是否需要立即人工介入，还是可观察/低优先。

## 高频根因模式（tipsy 实战字典）

| 现象签名 | 大概率根因 | 验证方向 |
|---|---|---|
| 多接口**同刻** 5xx + `QueuePool limit ... reached` | 共享 DB 连接池瞬时打满（非单接口 bug） | 看是否单实例、是否有慢操作长持连接 |
| 503 `No available channel` / `model_not_found`，用某模型**每次必失败** | 模型在 newapi 网关无 channel（确定性，非瞬态） | 看 `chat.provider_error` 的 model 名；区别于 `no healthy upstream`（瞬态基础设施） |
| 503 `no healthy upstream`，夹大量 200，自愈 | 网关瞬态 | 不是确定性，别误判成模型配置问题 |
| wake 500/503 message 显示 `greenlet_spawn` | 次生异常掩盖真因 | 捞 `sandbox.wake.failed` 的 `exception` traceback 看 L1 真因 |
| `Input is too long` 请求直接失败 | 上下文压缩失效/某会话异常膨胀 | 看检查点/压缩是否命中，估算 input 长度 |
| 审核类 403（性内容等） | 内容被审核拦截，非 bug | 按 `audit_metadata.session_id` 看 `audit.rejected` 日志，**看日志不看 span** |
| 长生成偶发 504、retryable | newapi 网关对 ~100s 长 idle 超时 | 0.x% rare，重发即可；反复 504=该轮太重 |
| 前台 ~600s 断连但后台还在跑 | CF/Traefik 砍前台 HTTP/SSE，后台 drain 继续 | 看 `*.detached` / `drain.finished`，不是应用 600s 常量 |

> 这些是历史案例沉淀，**会随代码演进失效**——当作「先验」缩小排查范围，不要当结论直接抄。每次都要用当前数据 + 代码重新确认。

## 取证小抄

- 完整链路：`WHERE trace_id = '...' ORDER BY start_timestamp ASC`。
- 完整 traceback：`attributes->>'exception'`（有 logger.exception 时）。
- 同一会话所有 run：`WHERE attributes->>'session_id'='...'`。
- 生成 UI 链接给人看：`project_logfire_link` / `project_logfire_ui_link`。
- `issue_list` 看聚合后的异常 issue。

## 下一步

- 根因定了、要判断优先级 → `quant-decision.md`。
- 要长期盯这个根因 → `dashboard-panels.md` 建 panel + `monitoring-loop.md` 加 alert。
