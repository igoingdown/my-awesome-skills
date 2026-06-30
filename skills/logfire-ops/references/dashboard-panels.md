# dashboard-panels：在 Logfire 看板里增/改/删 panel

Logfire 看板是 **Perses 兼容 JSON**。一个看板 = `variables`（全局变量）+ `panels`（panel 字典，按 `panel_key` 索引）+ `layouts`（Grid 分组与每个 panel 的位置）。

## 黄金法则：先 get 一个现有 panel 当模板，再改

**永远不要凭空手写 panel JSON。** panel 的 query/plugin 结构嵌套很深，手写极易出错。正确姿势：

1. `dashboard_list` → 找到目标看板的 `slug`。
2. `dashboard_get(dashboard=<slug>)` → 拿到完整 JSON，**复制一个最接近你要做的 panel** 当模板。
3. 把模板里的 `query` / 标题 / 单位改成你要的，用 `dashboard_add_panel` / `dashboard_update_panel` 写回。

## 工具速查

| 工具 | 用途 |
|---|---|
| `dashboard_list(project, search=)` | 列看板，拿 slug |
| `dashboard_get(dashboard=slug)` | 导出完整 Perses JSON（当模板 / 版本控制） |
| `dashboard_add_panel(...)` | 加 panel（见下方参数） |
| `dashboard_update_panel(dashboard, panel_key, ...)` | 改 panel，**只传要改的字段** |
| `dashboard_remove_panel(dashboard, panel_key)` | 删 panel |
| `dashboard_create(...)` / `dashboard_delete(...)` | 建/删整个看板 |
| `dashboard_add_variable` / `dashboard_update_variable` | 看板级变量 |
| `dashboard_create_group` / `dashboard_reorder_groups` / `dashboard_toggle_group_collapse` | Grid 分组管理 |
| `dashboard_update_settings` | 改时间范围 / 刷新间隔 |

> 破坏性操作（`dashboard_remove_panel` / `dashboard_delete`）先跟用户确认，并先 `dashboard_get` 给用户看清要删的是哪个。

## panel 类型（plugin_kind）与对应 query kind

| plugin_kind | 用途 | query kind | query plugin kind |
|---|---|---|---|
| `TimeSeriesChart` | 折线/堆叠柱时序图 | `TimeSeriesQuery` | `LogfireTimeSeriesQuery` |
| `GaugeChart` | 仪表盘/单值刻度 | `TimeSeriesQuery` | `LogfireTimeSeriesQuery` |
| `BarChart` | 柱状图（占比） | `NonTimeSeriesQuery` | `LogfireNonTimeSeriesQuery` |
| `PieChart` | 饼图 | `NonTimeSeriesQuery` | `LogfireNonTimeSeriesQuery` |
| `Table` | 表格（明细/汇总） | `NonTimeSeriesQuery` | `LogfireNonTimeSeriesQuery` |
| `Values` | 大数字 KPI（单值统计） | `NonTimeSeriesQuery` | `LogfireNonTimeSeriesQuery` |
| `Markdown` | 静态说明文字 | 无 query（`queries=[]`） | — |

**铁律**：
- 时序类（`TimeSeriesChart`/`GaugeChart`）的 query **必须含时间列并 GROUP BY 时间轴**，配合 `time_bucket($resolution, start_timestamp)`。
- 非时序类（Bar/Pie/Table/Values）用 `LogfireNonTimeSeriesQuery`，按看板时间范围聚合。
- query kind 与 plugin_kind 配错会渲染失败——对照上表。

## add_panel 参数（真实形态）

```jsonc
dashboard_add_panel(
  dashboard = "studio-chat-count-writer",      // slug
  panel_key = "ts_5xx_rate",                   // 看板内唯一 key
  name      = "5xx 趋势 by route",
  description = "每条折线一个 route 的 5xx 计数",
  plugin_kind = "TimeSeriesChart",
  plugin_spec = {                               // 可选，视觉配置
    "yAxis": {"show": true, "label": "5xx"},
    "legend": {"mode": "list", "position": "bottom"},
    "visual": {"display": "line", "areaOpacity": 0.3}
  },
  queries = [{
    "kind": "TimeSeriesQuery",
    "spec": {"plugin": {
      "kind": "LogfireTimeSeriesQuery",
      "spec": {
        "query": "SELECT time_bucket($resolution, start_timestamp) AS x, http_route AS route, COUNT(*) AS amount FROM records WHERE http_response_status_code >= 500 AND deployment_environment = ANY($env::text[]) GROUP BY x, http_route ORDER BY x LIMIT 2000",
        "groupBy": "route",
        "metrics": ["amount"]
      }
    }}
  }],
  layout = {"group_index": 0, "x": 0, "y": 0, "width": 12, "height": 8, "sort_order": 0}
)
```

### Values（大数字 KPI）panel —— query 用 `AS amount`

```jsonc
plugin_kind = "Values",
queries = [{"kind":"NonTimeSeriesQuery","spec":{"plugin":{"kind":"LogfireNonTimeSeriesQuery","spec":{
  "query": "SELECT COUNT(*) AS amount FROM records WHERE http_response_status_code >= 500 AND deployment_environment = ANY($env::text[])"
}}}}]
```

### Table panel —— 列名用 `AS "中文列名"`，明细带 trace_id 方便点进详情

```jsonc
plugin_kind = "Table",
queries = [{"kind":"NonTimeSeriesQuery","spec":{"plugin":{"kind":"LogfireNonTimeSeriesQuery","spec":{
  "query": "SELECT start_timestamp AS \"Time\", http_route AS \"Route\", attributes->>'error' AS \"Error\", trace_id AS \"Trace\" FROM records WHERE http_response_status_code >= 500 ORDER BY start_timestamp DESC LIMIT 100"
}}}}]
```

### Markdown panel —— 写「如何读这个看板」说明，无 query

```jsonc
plugin_kind = "Markdown",
plugin_spec = {"text": "**用途**：...\n\n**健康判定**：正常 X≈Y；异常 ..."},
queries = []
```

## 看板变量（让 panel 可交互过滤）

实战中两类变量几乎必配，query 里用 `$变量名` 引用：

1. **时间分辨率** `resolution`（时序图分桶用）——`TimeBucketVariable`，通常 hidden：
   ```jsonc
   {"kind":"ListVariable","spec":{"name":"resolution","display":{"name":"Resolution","hidden":true},
     "allowMultiple":false,"allowAllValue":false,
     "plugin":{"kind":"TimeBucketVariable","spec":{}}}}
   ```
   用法：`time_bucket($resolution, start_timestamp) AS x`。

2. **环境多选** `env`——`StaticListVariable` + `allowMultiple:true`：
   ```jsonc
   {"kind":"ListVariable","spec":{"name":"env","display":{"name":"Environment"},
     "defaultValue":["prod"],"allowMultiple":true,"allowAllValue":true,
     "plugin":{"kind":"StaticListVariable","spec":{"values":["prod","dev","test"]}}}}
   ```
   **多选变量用 `= ANY(...)`，不能用 `=` 或 `LIKE`**：`deployment_environment = ANY($env::text[])`。

## 布局（layout / Grid）

- 宽度 `width` 是 1–24 的栅格单位（满宽 = 24）。
- `group_index` 指定 panel 落在第几个 Grid 分组；`x/y` 定位，`sort_order` 排序。
- 分组有标题与折叠态（`display.title` + `collapse.open`）。
- 加 panel 时如果不关心位置，给个 `{"width":12,"height":8}` 即可，之后可在 UI 拖动或用 `dashboard_update_panel` 调 `layout`。

## 改 panel（只传变更字段）

```jsonc
dashboard_update_panel(
  dashboard = "studio-chat-count-writer",
  panel_key = "ts_5xx_rate",
  name = "5xx 趋势 (prod)",            // 只改名
  // 其余字段不传 = 不动
)
```
要改 query 就传新的 `queries`（整组替换）。

## 改看板时间范围 / 刷新间隔

```jsonc
dashboard_update_settings(dashboard=slug, duration="24h", refreshInterval="60s")
```

## 完整工作流示例：「给 ddd 看板加一个 5xx 趋势图」

1. `dashboard_list(project="tipsy", search="ddd")` → slug = `ddd`。
2. `dashboard_get(dashboard="ddd")` → 找一个已有的 `TimeSeriesChart` panel 复制其结构，确认它用的变量名（`$resolution` / `$env`）。
3. 改 query 为 5xx 统计，`dashboard_add_panel(...)` 写回（panel_key 取个没用过的，如 `ts_5xx_rate`）。
4. `dashboard_get` 复核 panel 已在；把 Logfire UI 链接给用户。

## 下一步

- 看板做好了想自动盯 → `monitoring-loop.md`（建 alert + /loop 巡检）。
- 看板上发现异常 → `rca-trace.md` 下钻根因。
