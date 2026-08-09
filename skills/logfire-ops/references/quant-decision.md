# quant-decision：用数据判断「值不值得修」

定位了一个问题后，别急着修。先用历史数据量化它的**频率 × 影响面 × 趋势 × 严重度**，给出优先级建议。目标是把「感觉是个 bug」变成「7 天 N 次、影响 M 个项目、趋势平稳、用户无硬失败 → 低优先」这种可决策的结论。

## 四个维度

### 1. 频率（多久发生一次）

```sql
-- 近 14 天该问题的总次数 + 按天分布
SELECT date_trunc('day', start_timestamp) AS day, count(*) AS cnt
FROM records
WHERE deployment_environment='prod'
  AND message = 'chat.provider_error'           -- 换成你的问题签名
  AND attributes->>'error' ILIKE '%no available channel%'
GROUP BY day
ORDER BY day
LIMIT 30
```

判读：是「7 天 1 次极罕见」还是「每天稳定 N 次」还是「突然爆发」。

### 2. 影响面（波及多少独立实体 / 是否集中在个别）

```sql
-- 波及多少独立 project / session，是否高度集中（个别惯犯 vs 普遍）
SELECT count(*) AS total_events,
       count(DISTINCT attributes->>'project_id') AS distinct_projects,
       count(DISTINCT attributes->>'session_id') AS distinct_sessions
FROM records
WHERE deployment_environment='prod'
  AND message = 'chat.provider_error'
```

```sql
-- Top 受影响实体：是否 90% 集中在一个 session（→ 个案，可能非系统性）
SELECT attributes->>'session_id' AS session_id, count(*) AS cnt
FROM records
WHERE deployment_environment='prod' AND message='chat.provider_error'
GROUP BY session_id
ORDER BY cnt DESC
LIMIT 20
```

判读：**1000 次但全在 1 个 session** vs **100 次散在 80 个项目**——后者系统性强、优先级更高。「distinct≥2 且分散」往往才是系统性问题。

### 3. 严重度（用户是否硬失败）

- 用户**硬失败**（请求直接 4xx/5xx、对话中断）→ 高严重度。
- **静默降级**（fallback 到确定性结果，用户无感）→ 低严重度，即使频率高也可缓。
- 烧钱/烧算力（如空转十几分钟）→ 即使用户无感也值得修（成本维度）。

```sql
-- 占比：这个问题占该接口总请求的多大比例（算 SLI 影响）
SELECT
  count(*) FILTER (WHERE http_response_status_code >= 500) AS errors,
  count(*) AS total,
  round(100.0 * count(*) FILTER (WHERE http_response_status_code >= 500) / count(*), 3) AS err_pct
FROM records
WHERE deployment_environment='prod' AND http_route = '/api/sdk/v1/respond'
LIMIT 1
```

### 4. 趋势（在变好还是变坏）

```sql
-- 按天看是否上升趋势（决定「现在修 vs 观察」）
SELECT date_trunc('day', start_timestamp) AS day, count(*) AS cnt
FROM records
WHERE deployment_environment='prod' AND is_exception
  AND span_name LIKE 'chat %'
GROUP BY day ORDER BY day LIMIT 30
```

判读：平稳的低频问题可「观察+建告警兜底」；上升趋势的要尽快处理；新出现（首次）的要警惕。

## 决策框架

综合四维给一个结论，落到下面四档之一：

| 档 | 条件 | 建议 |
|---|---|---|
| **立即修** | 用户硬失败 + （频率高 或 上升趋势 或 影响面广） | 排 P0/P1，给修复方案 |
| **排期修** | 用户硬失败但低频平稳，或无硬失败但烧钱/趋势上升 | 进 backlog，建 panel/alert 盯着 |
| **观察** | 低频 + 良性/自愈 + 平稳 + 影响集中 | 不动代码，建 alert 兜底，写进 Observation Gap 持续观察基线 |
| **不修（结案）** | 个案 / 测试数据 / 探针噪声 / 规则按设计工作 | 说清为什么不是 bug，留证据备查 |

## 写结论的规范

每个判断都带数字和证据，例如：

> 近 14 天 N 次，散在 M 个独立 project（非个别惯犯），全部 fallback 到确定性截断、用户无硬失败，趋势平稳。命中既有告警阈值属正常波动。**结论：真实但良性，建议「观察」——保留 alert 兜底，不专门修。**

避免：
- 把「瞬态自愈」当事故拉高优先级。
- 把「个别 session 刷出来的高计数」当系统性问题。
- 没算影响面/趋势就拍脑袋说「得修」。
- 把「测试数据/探针噪声」当真实用户问题。

## 易踩的坑

- **biz_id ≠ project_id**：算 distinct 项目时用日志里的内部 `project_id`；要回报给业务方再去 DB 映射 biz_id。
- **别只数 ERROR 级**：很多失败是 INFO/WARN 级或 200 流内，只 `WHERE level=17` 会严重低估频率。
- **窗口一致**：算频率/影响面/趋势用同一时间窗，别一个 7 天一个 30 天混着比。
- **观测盲区先承认**：detail 没进 span 时，先说「需补打点才能量化」，别用不全的数据下硬结论。

## 观测窗口与覆盖面：先说清「够不够」，别挑省事的口径

给量化结论时最容易翻车的两处不是算错，而是**取样的窗口和覆盖面缺省选了省事的那个，却没说自己缩了范围**。用户对这两点的追问极其一致：「为什么只取了近一小时？样本够吗？取过去 72 小时按分钟聚合有什么问题？很耗时吗？为什么不做？」「你只看了这两个端吗？其他端有看吗？」——省事的默认口径会被逐条戳穿，且一旦结论已经汇报出去再回填，返工成本更高。规则：

- **窗口默认要覆盖「从变更/观测起点到现在」的完整区间，缩窗必须给理由**。别默认拿「最近一小时」这种刚好够跑出个数的窗口就下结论——它既可能样本不足，也可能正好落在低谷/高峰而不具代表性。要么用完整区间（从功能上线/开始观测的那个时刻起算到现在），要么说清为什么截短（成本、噪声段），并说明短窗的样本量和代表性局限。用户会直接问「按分钟聚合到底耗不耗时」——先估算再决定，别拿「怕慢」当借口默默缩窗。
- **「跨端 / 跨环境 / 跨渠道一致」这类结论，覆盖面必须穷举所有端并逐端给数**。只测了其中两端就写「跨端一致」，是把子集结论冒充全集——用户会立刻追问漏掉的那几端（如某些平台的商店版与非商店版、Web 端各算一路）。先回代码/配置把**全部**端/渠道枚举出来，逐端给样本量和一致性表现；某一端样本为零或拿不到数据，显式标「该端未覆盖」，不要让读者以为结论覆盖了全部。
- **门控/分支逻辑因端而异时，一致性口径要按端分别定义**。不同端的开关、灰度、商店合规门控可能不同，同一个「一致性」指标在各端的分母口径未必相同；先看清每端的分支逻辑，再谈能不能横向比。

## 给非技术方的汇报：先结论后依据，一定要有信息量

把量化结论汇报给老板/产品这类非技术方时，常见翻车是**为了「说人话」把信息量也砍没了**——「监控已上线，连续观察 7 天就能自动报警」这种话没有任何量化信息，会被打回。字数限制不等于信息量限制。规则：

- **结构固定为「先给观点和结论 → 再给支撑结论的依据和逻辑 → 有实例贴一个实例」**。开头一句就是可判定的结论（达成/未达成 + 关键数字），不要用「已上线/已保通」这种过程陈述占掉结论位。
- **每个结论后面挂量化依据**：取了多长的数据、什么口径、覆盖哪些端/榜单、观测周期多长、结论是什么数值。「近期数据」要具体到「从某时刻起的多少小时」，「各榜单」要点名是哪几个，别用模糊集合词。
- **字数由信息量决定，不由「越短越好」决定**。用户先要 100 字被嫌没信息量，扩到 500 字要求「有数据、有逻辑、有实例」——先保证信息完整，再在此前提下压缩措辞。

## 下一步

- 判「立即修/排期修」→ 进入修复（接 `rca-trace.md` 的方案）。
- 判「观察」→ `monitoring-loop.md` 建 alert + `dashboard-panels.md` 建 panel 盯基线。
