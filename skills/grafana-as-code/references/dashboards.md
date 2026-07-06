# 看板(dashboards)

> 前提:已按 SKILL.md §0 `source secrets.sh`。

看板走**经典 API**(`POST /api/dashboards/db`),与告警的 Provisioning API 不同通道,同
host/token(token 需 `dashboards:write`)。

## 推送:用 skill 自带的通用脚本(任何服务仓都可用)

推送脚本随 skill 分发(`<skill>/scripts/push_dashboard.py`),**不再依赖 tipsy-backend 的
deploy/grafana/**。各服务仓只保管自己的看板 JSON(如 tipsy-backend `deploy/grafana/dashboards/`、
tipsy-memory `deploy/observability/`),脚本一处维护:

```bash
SKILL_DIR="$HOME/.claude/skills/grafana-as-code"
python3 "$SKILL_DIR/scripts/push_dashboard.py" --dry-run --folder <目录名> <看板>.json   # 校验+lint,不连网
python3 "$SKILL_DIR/scripts/push_dashboard.py" --folder <目录名> <看板>.json            # 推送(可多个 JSON)
# 指定数据源:--datasource <name|uid>(或 env GRAFANA_DATASOURCE);不指定则自动探测
```

- 幂等:按 JSON 里的 `uid` 做 upsert(`overwrite=True`),重复推只更新不重建;folder 按标题
  派生稳定 uid,不存在自动创建。
- **用 folderUid,不用数字 folderId**(numeric id 在 Grafana 9+ 已弃用,脚本只走 folderUid)。
- 推完自动 read-back 校验看板确实落在目标 folder——写接口返回 success 不代表落对了位置。
- `--dry-run` 会跑规范 lint(下方图例/reducer 铁律),推送前先看一眼 lint 输出。

## 数据源清单与探测法(先探测,别猜)

本实例(`grafana-cn-c064otf0j01.grafana.aliyuncs.com`)有 **3 个 Prometheus 数据源**,
业务指标不一定在你以为的那个区域:

| 名称 | uid | 后端 | 用途 |
|---|---|---|---|
| `prometheus` | `efflgyrdjhyiof` | ARMS us-east-1(default) | **prod 业务指标**(tipsy-backend、tipsy-memory 均在此) |
| `prometheus-1` | `effliv7t33ncwd` | SLS us-east-1 | 日志类,**不响应标准 PromQL**,别 pin |
| `prometheus-test` | `dfflkx5ngtce8a` | ARMS cn-hongkong | 测试实例 |

新服务上看板前,**先用探测查询确认指标落在哪个源**(datasource proxy 只读,任何 token 可用):

```bash
# 对每个候选 uid 跑一次,看哪个返回非空 result
curl -sf "$GRAFANA_URL/api/datasources/proxy/uid/<uid>/api/v1/query" \
  -H "Authorization: Bearer $GRAFANA_TOKEN" \
  --data-urlencode 'query=count(<你的指标名>)' | python3 -m json.tool
```

教训:tipsy-memory 部署在 cn-hongkong ACK,但指标实际落在 **us-east-1** 的 ARMS 实例
(`efflgyrdjhyiof`)——按集群区域猜数据源会 pin 错,看板全空。

## 权限模型与 first-run 403(folder 白名单 SA 必读)

本实例的 token 通常是**按 folder 白名单授权的 service account**(非全局 Admin,如
`sa-1-api-auto-helper`)。两个后果:

1. **首次推新 folder 会 403**:SA 有 `folders:create`,建 folder 成功后 Grafana 会把该
   folder 的管理权授予创建者,但**同一次运行内不生效**——表现为"folder created + dashboard
   write 403"。**处置:原命令重跑一次即可**(脚本 403 时会提示这一点)。
2. 推到**别人的 folder** 403 是真没权限,找 folder 管理员在 folder permissions 里加该 SA。

## 看板 JSON 规范铁律

- **timeseries 图例一律用 table,且带 mean+max、按 mean 倒序**:每个 `timeseries` panel 的
  `options.legend` **必须**写
  `{ "displayMode": "table", "placement": "bottom", "showLegend": true, "calcs": ["mean", "max"], "sortBy": "Mean", "sortDesc": true }`。
  即图例渲染成下方表格,带 **Mean / Max** 两列并默认按 **Mean 倒序**(`sortBy` 用列显示名
  `"Mean"`,不是 reducer 名 `mean`)。单条 series 的趋势图(错误率/成功率/命中率)同样套这个,
  一行 Mean/Max 也有信息量。**例外**:`barchart` 桶图保持 `{ "showLegend": false }`,不套此规。
- **桶类 Counter**(amount/rows/batches 等带 bucket label):用 **barchart + instant +
  format=table**,bucket label 作 x 轴,**不能 `histogram_quantile`**。
- **reducer 一律用 `mean`,不要用 `lastNotNull`(=Last)**:所有带 calculation/reducer 的
  panel(stat / gauge / bargauge,即 `options.reduceOptions.calcs`)**必须**写 `["mean"]`。
  `lastNotNull` 只取时间窗内最后一个采样点,瞬时抖动/采样错位会让哨兵数字与趋势图严重不符、
  极易误导(把一瞬间的尖刺当成稳态)。比率/QPS/延迟分位数哨兵都改 `mean` 取窗口平均更稳健。
  ⚠️ 注意区分:timeseries 图例里的 `legend.calcs:["mean","max"]` 是**图例统计**(只是表格列),
  不是 reducer,不受本条(`reduceOptions.calcs`)约束——它由上一条「timeseries 图例一律用 table」
  单独强制。
- **多副本 Gauge** 面板同样要显式 `sum()`/`max()` 聚合,否则多 pod 数字会乱跳。
- 想搞清某看板实际画了哪些指标(决定该不该加告警):`scripts/diagnostics/dump_dashboard.py`
  (见 `references/diagnostics.md`)。

## 已登记看板(按服务)

| 服务 | 看板 uid | folder | 指标前缀 | 看板 JSON 所在仓库 |
|---|---|---|---|---|
| tipsy-backend | (多块,见 tipsy-backend 仓) | Tipsy Backend | `tipsy_*` / `gin_*` | tipsy-backend `deploy/grafana/dashboards/` |
| tipsy-memory | `tipsy-memory` | memory-service | `tipsy_memory_*` | tipsy-memory-demo `deploy/observability/grafana-dashboard.json` |

改完务必 `git diff` 审查再提交。
