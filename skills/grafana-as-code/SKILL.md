---
name: grafana-as-code
description: >
  Tipsy 后端的 Grafana「告警即代码 / 看板推送 / 阈值校准」操作 skill。当用户要新增或修改
  Grafana 告警规则、推送或更新看板(dashboard)、校准告警阈值、排查告警误报/漏报时使用。
  封装 deploy/grafana/ 下的 DRY spec→generate→validate→push 工作流(tipsy-backend 与
  recsys 两套告警)、看板 JSON 推送(push_dashboard.py)、以及 diagnostics 校准/诊断脚本。
  典型触发:"加一条告警"、"改告警阈值"、"推个看板 / 更新看板"、"告警在误报"、"校准阈值"、
  "push 到 grafana"、"新建一个 dashboard 面板"。环境为阿里云托管 Grafana + ARMS Prometheus。
---

# Grafana as Code (Tipsy)

把"高优指标 → 告警/看板"做成 **DRY 单一事实源 + 一键生成 + 托管 Grafana 可落地**。
本 skill 只负责**编排 + 护栏**,不复制脚本逻辑——真正干活的脚本是单一事实源,在仓库的
`deploy/grafana/`。

环境:阿里云托管 Grafana `grafana-cn-c064otf0j01.grafana.aliyuncs.com`,数据源 ARMS
Prometheus uid `efflgyrdjhyiof`(**prod 专属**,跨环境 uid 不同),告警统一上报飞书联系点
`feishu-tipsy-alerts`(经 CF Worker + HMAC)。

## 和 logfire-ops 的边界("读告警"歧义先看这里)

本 skill 与 `logfire-ops` 都涉及"告警/看板",但**监控对象不同,不要混用**:

- **grafana-as-code(本 skill)= 基础设施指标**:Grafana alert 盯的是 ARMS Prometheus 指标
  (内存、circuit_state、时延桶、namespace 等),告警走 `deploy/grafana/` 的
  spec→generate→push;看板走经典 Grafana API。
- **logfire-ops = 应用层 telemetry**:Logfire alert 盯的是应用 trace/日志信号
  (Input too long、newapi 渠道缺失 503、sunrise 等);看板是 Logfire dashboard(Perses)。

本 skill 的强项是**写**:加/改告警规则、校准阈值、推看板。**当用户只说"读一下线上告警"
未指明平台时**,那多半是想**看现有告警状态**——若指基础设施指标(内存/时延/Prometheus)用本
skill;若指应用层 telemetry 告警,那属于 logfire-ops。**不确定就先反问澄清**,别默默猜一个。

---

## 按任务读对应手册(分层暴露,只读当前任务相关那份)

| 你要做的 | **先读** | 关键纪律 |
|---|---|---|
| 新增/修改告警规则、排查告警误报 | `references/alerting.md` | **写告警前必读**——含 circuit_state/时延/namespace 等指标陷阱铁律 |
| 推送/更新看板(dashboard) | `references/dashboards.md` | 看板走经典 API,与告警不同通道 |
| 校准阈值 / 诊断误报根因 | `references/diagnostics.md` | **写任何阈值前必读**——先查真实 series,不凭假设 |

> 这些 references 平时不占上下文,按需读取。**不确定该读哪份就先读 alerting.md**(覆盖面最广)。

---

## §0 前置:每次操作前必做(凭证 + 定位)

凭证不落盘,运行时从 secrets.sh 注入;脚本目录在仓库的 `deploy/grafana/`。把下面这串作为
每个 grafana 命令的前缀(**不要 `echo $GRAFANA_TOKEN`、不要写进任何文件**):

```bash
source "$HOME/github/my_dot_files/secrets.sh"      # 注入 GRAFANA_URL / GRAFANA_TOKEN
cd "$(git rev-parse --show-toplevel)/deploy/grafana" || { echo "本仓无 deploy/grafana,换到 tipsy-backend 仓再用"; exit 1; }
[ -n "$GRAFANA_TOKEN" ] || { echo "secrets.sh 未注入 GRAFANA_TOKEN"; exit 1; }
```

> **前提**:`deploy/grafana/` 须在当前仓库内。若它还没提交(早期在 `feature/alerts`
> worktree 未提交),换 clone 会找不到 —— 先把它提交进仓库,再跨项目用本 skill。

---

## 跨切面铁律(任何操作都适用 —— 违反必出事)

1. **token 不落盘**:`GRAFANA_TOKEN` 只在运行时由 secrets.sh 注入 env,绝不写 .env、不
   `echo`、不提交。
2. **数据源 uid `efflgyrdjhyiof` 是 prod 专属**:看板/告警都用它,换环境 uid 不同。
3. **改全局 Grafana 资源前先确认不冲别人**:通知策略 root、联系点是全局单资源,推之前务必
   确认不会冲掉其他团队的路由(告警 `make push` 默认已不动它们,详见 alerting.md)。
4. **跨服务告警/看板就近放各自仓库**(指标归属者维护),别把 K8s/Pineapple 等基础设施告警
   塞进本后端仓。

> ⚠️ **能力专属的铁律**(circuit_state=1 可用、gin 时延桶上限陷阱、namespace 混服务过滤、
> 比率必 clamp_max、多副本 Gauge 必聚合…)在 `references/alerting.md` —— **写告警必读那份**,
> 历史上最大的误报事故都出在这些点上。

---

## 收尾 / 更深问题

- 各能力的故障速查见对应 `references/*.md`。
- 开放问题(阈值校准清单、现网指标 bug、recsys 文件夹迁移)见
  `deploy/grafana/alerting/NOTES.md` 与 `deploy/grafana/PROGRESS.md`。
- 改完 `deploy/grafana/` 务必 `git diff` 审查再提交。
