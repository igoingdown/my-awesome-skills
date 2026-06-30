# 看板(dashboards)

> 前提:已按 SKILL.md §0 `source secrets.sh`。

看板走**经典 API**(`POST /api/dashboards/db`),与告警的 Provisioning API 不同通道,同
host/token(token 需 `dashboards:write`)。

```bash
cd "$(git rev-parse --show-toplevel)/deploy/grafana/scripts"
python3 push_dashboard.py --dry-run ../dashboards/<file>.json    # 预览,不连网
python3 push_dashboard.py ../dashboards/<file>.json             # 推送(省略路径=推全部)
# 放进指定文件夹:GRAFANA_FOLDER_ID=<数字id> python3 push_dashboard.py ...
```

- 幂等:按 JSON 里的 `uid` 做 upsert(`overwrite=True`),重复推只更新不重建。
- 看板 JSON 里每个 panel + target 的 `datasource.uid` **写死 `efflgyrdjhyiof`** 即导入即用
  (prod 专属,跨环境不同)。
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

改完务必 `git diff` 审查再提交。
