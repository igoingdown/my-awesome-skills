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
6. **同一现象优先做成比例口径,不做计数口径**:计数会随流量/放量同步涨,阈值要跟着业务反复上调,
   噪音最大;比例(失败数/总数、降级路径占比)对流量波动免疫,阈值一次定死。只有「正常应为 0」的
   事件型条件才用计数。选口径时顺带确认分母的埋点覆盖是否完整——分母缺埋点的比例比计数更危险。
7. **聚合维度必须留下能定位处置对象的标签**:`max by (instance)` / `sum by (job)` 这类写法会把
   pod / 容器名聚合掉,通知里只剩一个连接地址,收到的人不知道该去看谁。托管 serverless 容器运行时
   (虚拟节点形态)下更隐蔽:整个指标族的 `instance` 只有虚拟节点那一个聚合口,`by (instance)` 等于
   没分组,表达式实际算的是「当前最胖的那个容器」,而告警文案会把它读成「某台机器」。按能直接定位
   对象的维度分组(pod + namespace),推送前自问一句「照这条通知,人知道去看哪个实例吗」。
   配套:选指标前先确认该指标族在当前运行时**真的有 series**——虚拟节点下节点级 / 卷统计类指标
   可能整族为空,只有容器文件系统类指标可用;按经典节点模型写的规则会长期不触发,或指向错误主体。
8. **`description` 里的影响与处置断言同样要回运行时核**:描述常按标准运行时假设写后果(「盘满会导致
   pod 被驱逐」)。换到托管 serverless 形态,驱逐机制可能压根不生效(无 DiskPressure、未设
   ephemeral-storage limit),真实后果是写入直接报错而进程仍然存活、健康检查照过——比被驱逐重启更难
   发现。命中容量 / 资源类告警时先核这条运行时下真实会发生什么,再照描述给处置;描述与实际不符的,
   同一轮把规则文案一起改掉。容量类还要**算稳态余量而不是只报当前占比**:给增长速率(用另一个独立
   指标交叉验证量级)、周期性回收(日志轮转 / 清理任务)会带走多少,据此算「会不会自己降下去」与撑满
   ETA,并把「赌自愈」与「人工干预」两条路的判据和代价一起交用户定。只报「当前 90%」不构成可决策信息。

---

## 故障速查

- `make push` 整组报 500 → 正常,看脚本是否已自动逐条回退、逐条是否 200/201。
- 权限端点说没 `alert.provisioning:write` → 可能漏报,看实际推送结果。
- 规则推上去 UI 变只读 → 检查是否带了 `X-Disable-Provenance: true`(push.py 默认带,除非
  `--no-provenance`)。
- 改完线上仍误报 → 确认 `make push` 真的推了(generated/ 有没有 commit、push 汇总几组成功)。

> 更深的开放问题(阈值校准清单、现网指标 bug、recsys 文件夹迁移)见
> `deploy/grafana/alerting/NOTES.md` 与 `deploy/grafana/PROGRESS.md`。
