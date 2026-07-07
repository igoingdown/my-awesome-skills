---
name: family-travel-planner
description: >
  带宠物家庭自驾旅行规划。给定起点、终点、旅行天数和假期类型，
  生成完整的宠物友好旅行方案（自驾+火车），包含避峰日期推荐、
  充电计划（理想4C优先，参考信息请通过理想APP确认）、
  区域住宿推荐和景点推荐。
  当用户说"帮我规划XX到XX的旅行"、"五一出行方案"、
  "带狗自驾"、"假期旅行规划"、"家庭旅行"等时触发此 Skill。
  车型为 Tesla Model Y，充电优先选择理想4C超充站。
argument-hint: --origin <起点> --destination <终点> --days <天数> [--holiday <假期类型>]
user-invocable: true
allowed-tools: Bash, Read, Write
---

# Family Travel Planner

带宠物家庭自驾旅行规划，生成完整的宠物友好旅行方案。

## 功能

- **避峰日期推荐**：基于高德地图API + 节假日拥堵系数，推荐最优出发/返程日期
- **自驾方案**：路线规划 + 充电计划（理想4C优先） + 区域住宿推荐 + 景点推荐
- **火车方案**：调研最新宠物乘车/托运政策，评估可行性
- **方案对比**：6维度对比自驾 vs 火车
- **避峰评估**：拥堵降低X% ±15%

## 环境变量（统一放 secrets.sh，敏感信息不进仓库）

脚本启动时若环境变量未设置，会 source `~/github/my_dot_files/secrets.sh`（可用 `SECRETS_FILE` 改路径）。需包含：

- `GAODE_API_KEY`: 高德地图 Web服务 API Key

### API Key 配置

把下面一行加进 `~/github/my_dot_files/secrets.sh`（参考 `secrets.example.sh`）：

```bash
export GAODE_API_KEY="你的Key"
```

### 高德 API Key 申请流程

1. 访问 [高德开放平台](https://lbs.amap.com/)
2. 注册账号并完成开发者认证
3. 进入 [应用管理](https://lbs.amap.com/dev/key/app)，创建新应用
4. 选择服务类型为 **Web服务**
5. 获取 API Key

## 使用方法

### 通过 Agent 自然语言触发

> 帮我规划五一北京到大连的旅行，带狗，开Model Y

> 五一出行方案，北京到大连，5天

> 帮我规划国庆北京到青岛的自驾游

### 命令行执行

```bash
# 先编译（仅首次需要）
cd ~/.agents/skills/family-travel-planner
npm install
npm run build

# 执行
node dist/index.js --origin 北京 --destination 大连 --days 5 --holiday 五一
```

### 参数说明

| 参数 | 必填 | 说明 | 示例 |
|------|------|------|------|
| `--origin` | 是 | 出发城市 | `北京` |
| `--destination` | 是 | 目的城市 | `大连` |
| `--days` | 是 | 假期总天数 | `5` |
| `--holiday` | 否 | 假期类型 | `五一`、`国庆`、`春节` |

## 拥堵系数说明

拥堵系数根据三个维度动态计算：

1. **路线方向**：出城方向（×2.0）/ 进城方向（×1.8）
2. **时段**：早高峰（×1.8）/ 晚高峰（×1.6）/ 平峰（×1.2）
3. **假期阶段**：第1天（×2.5）/ 中间（×1.3）/ 最后1天（×2.2）/ 假期后（×1.1）

综合系数 = 方向系数 × 时段系数 × 假期阶段系数 / 2.0

可在 `src/config.ts` 中调整系数。

## 充电站搜索策略

1. **优先**：高速服务区内理想4C超充
2. **备选**：极氪超充、其他≥480kW超充
3. **排除**：<120kW慢充、需要排队的桩
4. **绕行上限**：单程<10km 且 <10分钟
5. **备选站点**：至少2个

> ⚠️ 充电站信息仅供参考，请通过理想APP确认具体站点位置和可用性

## 输出格式

输出为 Markdown 格式，包含6个章节：

1. 避峰日期推荐
2. 自驾方案（路线+充电+住宿+景点）
3. 火车方案（含宠物托运）
4. 方案对比
5. 避峰评估
6. 待确认事项

## 技术实现

- **语言**：TypeScript
- **编译**：`tsc` → `dist/index.js`
- **依赖**：node-fetch
- **API**：高德地图开放平台（路线规划/POI搜索/交通态势）
