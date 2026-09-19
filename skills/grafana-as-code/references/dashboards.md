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
- `--dry-run` 会跑规范 lint(下方窗口/图例/override/reducer 铁律),推送前先看一眼 lint 输出。

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

> 下面前四条(窗口、图例、临时 override、分母)是用户亲手逐版校准一张基准看板后定下的口径,
> 替换了此前「mean+max 按 Mean 倒序」的老规矩。**用户手改过的看板就是样板**:再遇到用户说
> "我改了一版,你看看",先 diff 版本历史把改动归纳成规矩(改了哪些字段、为什么),同步进本文件与
> `push_dashboard.py` 的 lint,再以"全部看板 / 全部告警规则"为分母盘点哪些不符、每张一句话改法
> ——不是只评价那一张,更不能在别的看板上按老规矩再推一遍。

- **rate/increase 趋势窗口默认 `[1m]`,看板窗口与告警窗口分开定**:趋势类 timeseries 的
  `rate()/increase()/irate()` 一律写死 `[1m]`(抓取间隔 30s 时 1m 内有 2 个样本,足够);
  不再出现 `[5m]`/`[10m]`/`[1h]` 这类把尖刺抹平的窄图宽窗(日/周汇总类 stat/bargauge 用
  `$__range` 除外)。**唯一例外**是低流量分桶(1m 窗口下比例在 0%/100% 间跳、长时段一半是 NaN):
  可退到 `[5m]`,但必须在标题末尾标 "(5m 窗口)" 并在 description 写清为什么。**禁止
  `$__rate_interval`**——它随时间范围自动放大到 2–4 分钟,同一张图不同范围口径漂移,也让看板与
  告警对不上口径。**告警规则的窗口不跟看板机械改**:看板 1m 是看趋势,告警窗口决定 Pending 抖动
  与首触发时间,改前用近 14 天真事故窗口回放新旧窗口的触发次数再定,回测结果写进 spec。
- **timeseries 图例一律右侧表格、带 Last\* 与 Mean 两列、按 Last\* 降序**:每个 `timeseries`
  panel 的 `options.legend` **必须**写
  `{ "displayMode": "table", "placement": "right", "showLegend": true, "calcs": ["lastNotNull", "mean"], "sortBy": "Last *", "sortDesc": true }`。
  Last\* 回答"现在谁最差"(排最上面),Mean 回答"这段时间平均谁最差";`sortBy` 用列显示名
  `"Last *"`(带空格和星号),不是 reducer 名 `lastNotNull`。**排序一律降序**——升序会把最差的
  一条压到表格底部,看着像误点了排序箭头。多序列图再加 `options.tooltip = { "mode": "multi", "sort": "desc" }`。
  单条 series 的趋势图同样套用。**例外**:`barchart` 桶图保持 `{ "showLegend": false }`,不套此规。
- **不带临时 override 上线**:`fieldConfig.overrides` 里 `__systemRef: "hideSeriesFrom"`(隐藏某几条线)
  只允许排查时临时加,保存/推送前删掉——看板是给所有人看的,别人打开只看到你排查那一刻留下的几条线。
- **错误率/占比类面板的分母要覆盖全量流量,并写清分母是什么**:同一条链路常有多个计数指标
  (账号层全量请求 vs 某个出口的子集、流式 vs 非流式),分母选了子集会把主流量整段漏掉、比率失真;
  标题或 description 写明分子分母各是哪个指标。默认时间范围 6h–12h、refresh 1m。
- **duration/耗时类指标必须 P50、P90、P95、P99 四口径齐全,且一个分位一个 panel**:凡展示
  耗时(duration/latency/elapsed 等 histogram)的看板,**必须**同时给出 P50、P90、P95、P99
  四个 `histogram_quantile` 面板——**拆成四个独立 panel,不许把多个分位混进同一个 panel**
  (混在一起时 P50 会被 P99 的量级压成地板线,且按 series 排序/告警定位都变难)。四个 panel
  标题带口径后缀(如 `XXX Duration P50` / `... P90` / `... P95` / `... P99`),除
  `histogram_quantile(0.5|0.9|0.95|0.99, ...)` 的分位参数外查询完全一致,排布放同一行,
  方便横向对比。只画一两个分位(只有 P95/P99)视为不完整,补齐再推。
- **桶类 Counter**(amount/rows/batches 等带 bucket label):用 **barchart + instant +
  format=table**,bucket label 作 x 轴,**不能 `histogram_quantile`**。
- **reducer 一律用 `mean`,不要用 `lastNotNull`(=Last)**:所有带 calculation/reducer 的
  panel(stat / gauge / bargauge,即 `options.reduceOptions.calcs`)**必须**写 `["mean"]`。
  `lastNotNull` 只取时间窗内最后一个采样点,瞬时抖动/采样错位会让哨兵数字与趋势图严重不符、
  极易误导(把一瞬间的尖刺当成稳态)。比率/QPS/延迟分位数哨兵都改 `mean` 取窗口平均更稳健;
  确实要看"当前值"就另起一块用 `lastNotNull` 并在标题写"当前"。
  ⚠️ 注意区分:timeseries 图例里的 `legend.calcs:["lastNotNull","mean"]` 是**图例统计**(只是表格列),
  不是 reducer,不受本条(`reduceOptions.calcs`)约束——它由上面「timeseries 图例一律右侧表格」
  那条单独强制。
- **多副本 Gauge** 面板同样要显式 `sum()`/`max()` 聚合,否则多 pod 数字会乱跳。
- **推之前先查死指标**:看板引用的每个指标在目标数据源跑 `count(last_over_time(<m>[7d]))`,
  为 0 的面板要么删、要么标题标"事件型·常态 0";引用了下线服务/改名指标的面板会一直画空图,
  看板越攒越多时这类死面板占比不小,盘点全站看板时把"死指标面板数"作为一列一起报。
- 想搞清某看板实际画了哪些指标(决定该不该加告警):`scripts/diagnostics/dump_dashboard.py`
  (见 `references/diagnostics.md`)。

## 已登记看板(按服务)

| 服务 | 看板 uid | folder | 指标前缀 | 看板 JSON 所在仓库 |
|---|---|---|---|---|
| tipsy-backend | (多块,见 tipsy-backend 仓) | Tipsy Backend | `tipsy_*` / `gin_*` | tipsy-backend `deploy/grafana/dashboards/` |
| tipsy-memory | `tipsy-memory` | memory-service | `tipsy_memory_*` | 本地 `~/grafana-dashboards/tipsy-memory.json`(线上 v2 存档;仓库 `deploy/observability/grafana-dashboard.json` 是 v1,未跟进图例规范) |

改完务必 `git diff` 审查再提交。
