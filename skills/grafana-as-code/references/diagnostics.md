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

> 待校准清单(RSS/goroutine/各域 ratio·latency 阈值多为占位)见
> `deploy/grafana/alerting/NOTES.md` 与 `deploy/grafana/PROGRESS.md`。
