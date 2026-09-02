# 阈值校准 / 诊断(写告警阈值前必做)

> 前提:已按 SKILL.md §0 `source secrets.sh`。

`deploy/grafana/scripts/diagnostics/*.py` 全是**只读**(查 ARMS Prometheus,不改任何 Grafana
资源)。用法:`source secrets.sh` 后 `python3 scripts/diagnostics/<脚本>.py`。

**纪律:写任何阈值前先用它们查真实 series,别凭假设**——这是低噪音的前提,也是历史上最大的
踩坑来源(凭假设设 status/circuit 取值导致 Anthropic 三条规则全错、15 条持续误报)。

| 脚本 | 用途 |
|---|---|
| `calibrate.py` | 查 7 天基线,自动算每条规则建议阈值 |
| `recalibrate_1d.py` | 近 1 天 vs 7 天对比,剔除被故障污染的基线 |
| `baseline_llm_provider.py` / `baseline_fail_rate_gate.py` / `baseline_subscription.py` / `baseline_ttft.py` | 各域基线 |
| `diagnose_circuit.py` / `diagnose_llm_provider_alert.py` / `diagnose_mem.py` | 误报根因诊断 |
| `verify_fixes.py` / `verify_subscription.py` | 改完核对标签真实取值/指标覆盖 |
| `dump_dashboard.py` | 导出某看板实际用的指标(决定该不该加告警) |

校准出的阈值回填到 `alerting/alerts.spec.yaml`(或 recsys 那套),再走
`references/alerting.md` 的 generate → validate → push 流程。

> **问题修复上线后要主动回看相关告警阈值**:修复前的异常高水位会污染 7 天基线(用
> `recalibrate_1d.py` 剔除污染段再算);修复后水位整体下降,原阈值可能变得过松(漏报)
> 或仍按事故水位设定(永不触发)。等新水位稳定 1-2 天后按新基线重校准再推。

## 新告警上线前:先回放,不许"配上即报"

用户对告警噪音零容忍,原话形态是「配上就报,分析清楚再推上去」「没有实质影响的告警不要烦我,
我要非常低的噪音」。任何新建/改阈值的规则推上线前双向回放:

- **正向**:用历史出事窗口回放查询,确认真事故能命中;
- **反向**:用正常时段窗口回放,确认平时不命中。「配上即报」不是灵敏,是把常态当异常。

## warning / critical 分级规矩(用户明确定的,别自己发挥)

- **有兜底、未对用户造成恶劣影响的 → warning**;critical 只留给"用户可感 + 不可逆/需立即
  处置"的场景(critical 会给用户打电话,错级一次代价很高)。
- **warning 不进即时通知群**,只报 critical;某条 warning 若重要到需要被看见,要么调严升级成
  critical,要么落看板/日报。判据统一两问:用户是否可感 + 是否不可逆,答不出可感影响的一律
  不配即时推送级。

## 告警接收面按「谁会处理」路由(降噪、分级之外的第三件事)

告警治理不止阈值(降噪)和级别(分级),还有**路由**:每条规则响了给谁看、critical 电话打给谁。
用户的纠偏形态固定:「这个服务的告警我不会再看了,别发到共享告警群,发给我自己的账号」「这个服务
的 critical 要打电话给值班的另一位同学,怎么配」「这个服务只关心 CPU/内存告警,其他别报」。规矩:

- **接收面按归属划分,不按平台默认**:单人负责、前瞻类、试验类服务的告警,从共享值班群里摘掉,
  改发该负责人的个人通道;共享群只留多人要看的核心链路。
- **电话跟服务的值班人走**:某服务由另一位同学值班,该服务的 critical 电话就路由给那位同学,
  不是全部打给默认联系人。路由按规则的服务标签匹配(通知策略/联系点,或电话转发层的服务→值班人
  映射),改前先列清「这个服务现在有哪些规则会响、其中哪些会打电话、打给谁」,列表给用户确认再改。
- **按服务收窄规则集**:一个服务只关心部分资源告警时,只给它挂那几条,不把整套模板照搬——
  多出来的规则就是噪音源。
- **改路由 = 改共享通知策略,属处置类**:先出改动清单(哪些规则 → 哪个接收面),用户确认后再推,
  推完用一条真实/回放命中确认路由确实到了人,不能只看配置保存成功。改联系点前核对不会冲掉
  别人的路由(见 alerting.md 对全局联系点的警告)。

> 待校准清单(RSS/goroutine/各域 ratio·latency 阈值多为占位)见
> `deploy/grafana/alerting/NOTES.md` 与 `deploy/grafana/PROGRESS.md`。
