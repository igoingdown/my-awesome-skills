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
- **桶类 Counter**(amount/rows/batches 等带 bucket label):用 **barchart + instant +
  format=table**,bucket label 作 x 轴,**不能 `histogram_quantile`**。
- **多副本 Gauge** 面板同样要显式 `sum()`/`max()` 聚合,否则多 pod 数字会乱跳。
- 想搞清某看板实际画了哪些指标(决定该不该加告警):`scripts/diagnostics/dump_dashboard.py`
  (见 `references/diagnostics.md`)。

改完务必 `git diff` 审查再提交。
