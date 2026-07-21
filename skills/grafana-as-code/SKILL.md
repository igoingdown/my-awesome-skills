---
name: grafana-as-code
description: >
  org 全部后端服务的 Grafana「告警即代码 / 看板推送 / 阈值校准」操作 skill(tipsy-backend、
  tipsy-memory、recsys 等)。当用户要新增或修改 Grafana 告警规则、推送或更新看板(dashboard)、
  校准告警阈值、排查告警误报/漏报时使用。看板推送用 skill 自带通用脚本(scripts/push_dashboard.py,
  任何服务仓可用);告警封装 tipsy-backend deploy/grafana/ 下的 spec→generate→validate→push
  工作流;另含 diagnostics 校准/诊断。典型触发:"加一条告警"、"改告警阈值"、"推个看板 /
  更新看板"、"告警在误报"、"校准阈值"、"push 到 grafana"、"新建一个 dashboard 面板"。
  环境为阿里云托管 Grafana + ARMS Prometheus。
---

# Grafana as Code (Tipsy)

把"高优指标 → 告警/看板"做成 **DRY 单一事实源 + 一键生成 + 托管 Grafana 可落地**。
分工:**通用工具随 skill 分发**(`<skill>/scripts/`),**各服务的资产就近放各自仓库**
(看板 JSON、告警 spec 由指标归属者维护)。

环境:阿里云托管 Grafana `grafana-cn-c064otf0j01.grafana.aliyuncs.com`,**多数据源**——
prod 业务指标在 ARMS us-east-1(uid `efflgyrdjhyiof`),但新服务上板前**必须先探测**指标
落在哪个源(见 `references/dashboards.md` 数据源清单与探测法)。告警统一上报飞书联系点
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
| 推送/更新看板(dashboard) | `references/dashboards.md` | 用 skill 自带脚本;**先探测数据源**;folder-SA 首推 403 直接重跑;耗时(duration)指标必须 P50/P90/P95/P99 四口径、一分位一 panel |
| 校准阈值 / 诊断误报根因 | `references/diagnostics.md` | **写任何阈值前必读**——先查真实 series,不凭假设 |

> 这些 references 平时不占上下文,按需读取。**不确定该读哪份就先读 alerting.md**(覆盖面最广)。

---

## §0 前置:每次操作前必做(凭证)

凭证不落盘,运行时从 secrets.sh 注入(**不要 `echo $GRAFANA_TOKEN`、不要写进任何文件**):

```bash
source "$HOME/github/my_dot_files/secrets.sh"      # 注入 GRAFANA_URL / GRAFANA_TOKEN
[ -n "$GRAFANA_TOKEN" ] || { echo "secrets.sh 未注入 GRAFANA_TOKEN"; exit 1; }
```

工具定位(按任务二选一):

- **看板推送**:用 skill 自带脚本,无仓库依赖——
  `python3 "$HOME/.claude/skills/grafana-as-code/scripts/push_dashboard.py" --folder <目录> <JSON>`。
  看板 JSON 在当前服务仓里(tipsy-memory 为 `deploy/observability/`,tipsy-backend 为
  `deploy/grafana/dashboards/`)。
- **告警 / diagnostics**:脚本仍在 tipsy-backend 仓 `deploy/grafana/`(spec→generate→push
  与看板不同通道)——`cd` 到 tipsy-backend 后:
  ```bash
  cd "$(git rev-parse --show-toplevel)/deploy/grafana" || { echo "告警工作流须在 tipsy-backend 仓"; exit 1; }
  ```
  > ⚠️ 若该目录在你的 clone 里不存在,说明 feature/alerts 的产物仍未提交进主干——先把它
  > 落库,否则告警 as-code 工作流不可用(看板推送不受影响)。

---

## 跨切面铁律(任何操作都适用 —— 违反必出事)

1. **token 不落盘**:`GRAFANA_TOKEN` 只在运行时由 secrets.sh 注入 env,绝不写 .env、不
   `echo`、不提交。
2. **数据源先探测再 pin**:prod 业务指标在 `efflgyrdjhyiof`(ARMS us-east-1),但实例里有
   3 个 Prometheus 数据源,新服务的指标位置**用 count() 探测确认**,别按集群区域猜
   (tipsy-memory 部署在 cn-hongkong、指标却在 us-east-1)。
3. **改全局 Grafana 资源前先确认不冲别人**:通知策略 root、联系点是全局单资源,推之前务必
   确认不会冲掉其他团队的路由(告警 `make push` 默认已不动它们,详见 alerting.md)。
4. **跨服务告警/看板就近放各自仓库**(指标归属者维护),别把 K8s/Pineapple 等基础设施告警
   塞进本后端仓。通用脚本随 skill 分发,不复制进业务仓。
5. **监控产物不进 PR**(用户多次纠偏后定下的纪律):服务仓 grafana 部署目录下的看板 JSON、
   告警 spec/generated 产物,一律**不随业务代码 PR 提交**——推送靠脚本直连 Grafana,产物
   本地留档即可。提 PR 前自查 `git status` / diff,把这类文件从暂存区剔除;发现已混入的,
   先从 PR 里删掉再谈合入。

> ⚠️ **能力专属的铁律**(circuit_state=1 可用、gin 时延桶上限陷阱、namespace 混服务过滤、
> 比率必 clamp_max、多副本 Gauge 必聚合…)在 `references/alerting.md` —— **写告警必读那份**,
> 历史上最大的误报事故都出在这些点上。

## 收尾 / 更深问题

- 各能力的故障速查见对应 `references/*.md`。
- 开放问题(阈值校准清单、现网指标 bug、recsys 文件夹迁移)见
  `deploy/grafana/alerting/NOTES.md` 与 `deploy/grafana/PROGRESS.md`。
- 改完 `deploy/grafana/` 务必 `git diff` 审查;这些产物**不进业务代码 PR**(见铁律 5),本地留档即可。
