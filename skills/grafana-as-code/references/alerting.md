# 告警(alerting + alerting-recsys)

> 前提:已按 SKILL.md §0 `source secrets.sh` 并 `cd deploy/grafana`。

两套独立目录,工作流相同(改 spec → 生成 → 校验 → 推送):

| 目录 | 覆盖 | 落地文件夹 |
|---|---|---|
| `alerting/` | tipsy-backend 主服务(Anthropic / LLM Provider / Runtime / Voice Call / Core Payment / Gem Economy) | Tipsy Backend、Tipsy Subscription |
| `alerting-recsys/` | recsys 服务(DAG / Dependencies / HTTP / Operator / Runtime) | 仍落 Tipsy Backend(待迁 `RecSys Pineapple` uid `bfntkwgjkip6of`) |

**日常只动一个文件**:`<目录>/alerts.spec.yaml`(单一事实源,含 `fragments` / `defaults` /
`groups`)。新增核心路由只往 `fragments.CORE_API_RE` 加一段,相关规则自动生效;统一改
receiver/for/noData 改 `defaults`。

```bash
cd <alerting 或 alerting-recsys>
make generate     # spec → generated/rules/*.yaml(provisioning 格式)
make validate     # 校验可解析 + 无 <占位符> 泄漏
make dry-run      # 不连网,预览将发的 API 请求
make push         # 推送规则(复用现网联系点,需 GRAFANA_URL/GRAFANA_TOKEN)
```

- **`make push` 默认只推规则**,复用现网 `feishu-tipsy-alerts`,不动全局通知策略。
- `make push-all` 会改全局联系点(需额外 `FEISHU_WEBHOOK_URL`)——**慎用**,会冲掉别人的路由。
- push.py 策略:先整组 PUT,**托管版对"新建组"返回 500 是已知行为**,脚本自动回退逐条
  POST(逐条 200/201 即成功),不是故障。`--per-rule` 直接逐条、`--check` 只查权限。
- push.py 权限端点对服务账号常**漏报** `alert.provisioning:write`,以实际推送结果为准。
- push.py **无 DELETE**:要停一条规则用 spec 里加 `isPaused: true` 重推,别靠删(删了线上
  残留 uid 继续 firing)。

改完务必 `git diff generated/` 审查再提交。

---

## 告警专属铁律(违反必出事 —— 都是踩过的坑)

1. **写规则前先核对真实 series**,不凭假设设 status/circuit 取值(历史上 Anthropic 三条规则
   全因此写错,15 条持续误报)。先用 `references/diagnostics.md` 里的脚本查真实取值。常见陷阱:
   - `tipsy_anthropic_circuit_state`:**1=可用 / 0=熔断**(源码 `pkg/llm_anthropic/obs/metrics.go`),
     报警条件是 `==0` 不是 `>0`。
   - Anthropic 请求 status 真实取值 **ok/fail/refusal**,没有 `"error"`。
   - **时延别用 `gin_request_duration_seconds`**(桶上限 10s,P99 坍缩到 ≤10s,规则**永不触发**);
     用 `tipsy_http_request_duration_seconds`(180s 桶)。
   - LLM 错误率用 `tipsy_llm_provider_requests_total`(outcome),**别用 `tipsy_llm_requests_total`**
     (V2 流式/RichText 未埋点,口径残缺)。
2. **比率类必 `clamp_max` 封顶**,避免低流量下比率 >1 的毛刺误报;且所有 ratio/latency 规则
   加流量地板 `and QPS > X` + `noDataState: OK`。
3. **namespace=default 混了 4 个服务**(tipsy-chat/recsys/subscription/integration)。裸
   `go_goroutines`/`process_resident_memory_bytes` 会全捞 → 必须按 pod 名前缀过滤(见 spec 的
   `CHAT_POD` fragment);recsys 用 `app="tipsy-recsys"` 或 `tipsy-recsys-.*` pod 前缀。
4. **多副本 Gauge 必聚合**:掉坡类显式 `sum()`,泄漏类按单实例 `instance`,否则审计会看到
   "数字乱跳"。
5. **新告警"配上就报"是红线,推送前必须回测**:把最终告警表达式对近 7 天历史跑一遍
   (instant + range query,可复用 `references/diagnostics.md` 的脚本),确认触发次数符合预期
   ——应为 0,或恰好只命中已知事故窗口。回测不过就回去查 selector/指标是否真的存在
   (典型翻车:存活类规则的 job/pod 选择器写错,指标压根没有 series → 建好即 firing)。
   节奏解耦:**看板可以先推,告警必须回测通过后再推**;一批新规则里任何一条没回测,整批都别推。

---

## 故障速查

- `make push` 整组报 500 → 正常,看脚本是否已自动逐条回退、逐条是否 200/201。
- 权限端点说没 `alert.provisioning:write` → 可能漏报,看实际推送结果。
- 规则推上去 UI 变只读 → 检查是否带了 `X-Disable-Provenance: true`(push.py 默认带,除非
  `--no-provenance`)。
- 改完线上仍误报 → 确认 `make push` 真的推了(generated/ 有没有 commit、push 汇总几组成功)。

> 更深的开放问题(阈值校准清单、现网指标 bug、recsys 文件夹迁移)见
> `deploy/grafana/alerting/NOTES.md` 与 `deploy/grafana/PROGRESS.md`。
