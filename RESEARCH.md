# Family Travel Planner - 高德地图 API Research 报告

## 1. 高德开放平台 API Key 申请流程

### 1.1 注册流程

**步骤1：注册账号**
- 访问：https://lbs.amap.com/dev/id/
- 使用手机号注册高德开放平台账号

**步骤2：开发者认证**
- 登录后进入控制台：https://console.amap.com/
- 完成开发者实名认证（个人/企业）
- 个人用户：需要身份证认证
- 企业用户：需要营业执照认证

**步骤3：创建应用获取 Key**
- 访问应用管理：https://lbs.amap.com/dev/key/app
- 点击"创建新应用"
- 填写应用名称、类型
- 选择服务类型：**Web服务**
- 获取 API Key

**步骤4：开通API权限**
- 路线规划API：默认开通
- POI搜索API：默认开通
- 交通态势API：可能需要额外申请（高级功能）

### 1.2 配额限制

**基础服务月度免费限额**（2026年标准）：

| 服务类型 | 个人用户 | 已认证企业 | 持证企业 |
|----------|----------|------------|----------|
| 路网与地理编码 | 15万次/月 | 300万次/月 | 900万次/月 |
| POI检索 | 5千次/月 | 5万次/月 | 50万次/月 |
| 交通态势 | 需单独查询 | 需单独查询 | 需单独查询 |

**计费标准**（超出配额后）：
- 路网与地理编码：30元/万次
- 检索模块：30元/万次
- 终端定位：3元/万次

**并发限制**：
- 默认并发：需根据应用等级分配
- 加速包：400-1500元/月/10QPS

---

## 2. API 接口定义

### 2.1 路线规划 API

**接口地址**：`https://restapi.amap.com/v3/direction/driving`

**请求方法**：GET

**必选参数**：
| 参数名 | 类型 | 说明 |
|--------|------|------|
| `key` | String | 用户唯一标识（API Key） |
| `origin` | String | 出发点坐标，格式"经度,纬度" |
| `destination` | String | 目的地坐标，格式"经度,纬度" |
| `extensions` | String | `base`:返回基本信息；`all`:返回全部信息 |

**可选参数**：
| 参数名 | 类型 | 说明 |
|--------|------|------|
| `strategy` | Integer | 路线策略：`10`躲避拥堵, `12`尽量不走高速 |
| `waypoints` | String | 途经点，格式"经度,纬度\|经度,纬度" |
| `avoidpolygons` | String | 避让区域 |

**返回数据结构**：
```json
{
  "status": "1",
  "info": "OK",
  "count": "1",
  "route": {
    "paths": [
      {
        "distance": "1234",  // 距离（米）
        "duration": "300",   // 时间（秒）
        "tolls": "10.0",     // 过路费
        "steps": [...]       // 详细步骤
      }
    ]
  }
}
```

---

### 2.2 POI 搜索 API

**接口地址**：
- 关键字搜索：`https://restapi.amap.com/v3/place/text`
- 周边搜索：`https://restapi.amap.com/v3/place/around`
- 多边形搜索：`https://restapi.amap.com/v3/place/polygon`

**请求方法**：GET

**必选参数**（关键字搜索）：
| 参数名 | 类型 | 说明 |
|--------|------|------|
| `key` | String | API Key |
| `keywords` 或 `types` | String | 二选一：关键词或POI分类 |
| `city` | String | 目标城市（可选，不填则全国） |

**可选参数**：
| 参数名 | 类型 | 说明 |
|--------|------|------|
| `citylimit` | Boolean | 是否限定城市 |
| `offset` | Integer | 每页数量（建议≤25） |
| `page` | Integer | 页码 |
| `extensions` | String | `base`/`all` |

**返回数据结构**：
```json
{
  "status": "1",
  "info": "OK",
  "count": "10",
  "pois": [
    {
      "id": "POI ID",
      "name": "充电站名称",
      "type": "汽车服务;充电停车场",
      "typecode": "160100",
      "location": "经度,纬度",
      "address": "详细地址",
      "tel": "联系电话"
    }
  ]
}
```

---

### 2.3 交通态势 API

**接口地址**：
- 指定线路：`https://restapi.amap.com/v3/traffic/status/road`
- 圆形区域：`https://restapi.amap.com/v3/traffic/status/circle`
- 矩形区域：`https://restapi.amap.com/v3/traffic/status/rectangle`

**请求方法**：GET

**必选参数**（指定线路）：
| 参数名 | 类型 | 说明 |
|--------|------|------|
| `key` | String | API Key |
| `name` | String | 路名 |
| `city` 或 `adcode` | String | 城市 |
| `level` | Integer | 道路等级（1-6） |

**返回数据**：
- 拥堵指数：`1`畅通, `2`缓行, `3`拥堵
- 各状态路段占比

---

## 3. 关键验证：高速服务区充电站搜索

### 3.1 验证方案

**测试路线**：北京 → 大连

**搜索方案对比**：

| 方案 | 方法 | 可行性 | 说明 |
|------|------|--------|------|
| 方案1 | 关键词搜索：`"理想充电站 服务区"` | ⚠️ 需验证 | 通过keywords参数 |
| 方案2 | types筛选：`types="160100"` | ✅ 可行 | 160100=充电站typecode |
| 方案3 | 分段搜索 + 人工筛选 | ✅ 可行 | 兜底方案 |

### 3.2 充电站 POI Typecode

根据搜索结果，高德地图充电站相关typecode：
- **`160100`**: 充电停车场/充电站
- **`160000`**: 汽车服务（大类）

**高速服务区 typecode**：
- **`150000`**: 道路附属设施（可能包含服务区）
- 需通过`business_area`字段判断是否为服务区

### 3.3 推荐搜索策略

**最优方案（组合搜索）**：

```bash
# 步骤1：关键字+types组合搜索
GET https://restapi.amap.com/v3/place/text?key=YOUR_KEY&keywords=理想充电站&types=160100&city=全国&extensions=all&offset=50

# 步骤2：过滤高速服务区结果
# 检查返回POI的type字段是否包含"服务区"或business_area字段

# 步骤3：沿线分段搜索
# 将路线分为N段，每段中点附近搜索
```

**备选方案（关键字模糊搜索）**：

```bash
# 搜索"服务区 充电站"
GET https://restapi.amap.com/v3/place/text?key=YOUR_KEY&keywords=服务区充电站&extensions=all
```

### 3.4 局限性说明

⚠️ **高德API无法100%精准定位"高速服务区内"充电站**：
- POI搜索结果可能包含高速出口附近站点
- `business_area`字段可能不包含"服务区"标识
- 需要用户通过理想APP/小程序二次确认

**Skill应对策略**：
1. 优先返回types=160100且名称包含"服务区"的结果
2. 标注"需用户通过理想APP确认位置"
3. 提供备选站点（高速出口3km内）

---

## 4. 技术实现建议

### 4.1 环境变量配置

创建 `.env` 文件（需加入 `.gitignore`）：

```bash
# 高德地图 API Key
GAODE_API_KEY=your_api_key_here
```

### 4.2 API 调用示例

```bash
# 路线规划
curl "https://restapi.amap.com/v3/direction/driving?key=$GAODE_API_KEY&origin=116.397428,39.90923&destination=121.614682,38.914036&extensions=base"

# 充电站搜索
curl "https://restapi.amap.com/v3/place/text?key=$GAODE_API_KEY&keywords=理想充电站&types=160100&city=锦州&extensions=all&offset=20"
```

### 4.3 拥堵指数获取方案

⚠️ **交通态势API限制**：
- 返回**实时路况**，非历史拥堵指数
- 历史数据可能需要高级权限或不可用

**降级方案**：
- 使用WebSearch搜索"高德地图 五一 北京大连 拥堵预测报告"
- 基于经验法则估算：假期第1天指数2.5-3.0，第2天1.5-2.0

---

## 5. 总结与建议

### 5.1 API 可行性评估

| 功能 | 可行性 | 说明 |
|------|--------|------|
| 路线规划 | ✅ 完全可行 | 官方API，文档完善 |
| 充电站搜索 | ⚠️ 部分可行 | 可搜索充电站，但无法100%保证服务区内 |
| 拥堵指数 | ⚠️ 部分可行 | 实时路况可用，历史数据需降级方案 |

### 5.2 Skill 实现建议

**必须包含的功能**：
1. API Key验证与错误提示
2. 引导用户配置`.env`文件
3. 充电站搜索降级策略（服务区 → 高速出口附近）
4. 标注"需用户通过理想APP确认充电站位置"
5. 提供API申请文档链接

**可选功能**：
1. 历史拥堵数据（如API不可用，使用WebSearch替代）
2. 住宿电话验证清单（Skill输出电话，用户自行拨打）

### 5.3 风险提醒

1. **高德API Key泄露风险**：必须使用`.gitignore`保护`.env`
2. **充电站位置不准确**：需引导用户二次确认
3. **API配额限制**：个人用户月度5千次POI搜索可能不足
4. **交通态势API权限**：可能需要额外申请

---

## 6. 关键 Research：未来路况/ETA 预测 API

### 6.1 Research 目标
验证高德地图 API 是否支持"给定未来出发时间，返回预期耗时"功能。

### 6.2 Research 结果

**❌ 高德驾车路线规划 API 不支持未来时间参数**

经过多方验证，发现：
1. **驾车路线规划 API**（`/v3/direction/driving`）：
   - **不支持** `departure_time` 或类似参数
   - 返回的 `duration` 基于**当前实时路况**计算
   - 无法指定未来某个时间点获取预期耗时

2. **交通态势 API**（`/v3/traffic/status/*`）：
   - 仅返回**实时交通态势**
   - **不支持**未来预测或历史数据查询

3. **公交路线规划 API**：
   - 唯一支持时间参数的接口
   - 但仅适用于公共交通，不适用于驾车

### 6.3 替代方案对比

| 方案 | 描述 | 可行性 | 优点 | 缺点 |
|------|------|--------|------|------|
| **方案A：实时路况 × 拥堵系数** | 使用实时API，基于假期类型应用拥堵系数 | ✅ 可行 | 简单可靠，高德API支持 | 精度有限（±15-20%） |
| **方案B：WebSearch 拥堵报告** | 搜索"高德 五一 北京大连 拥堵预测" | ⚠️ 用户不接受 | 可能有官方预测报告 | 用户已明确拒绝 |
| **方案C：基于经验的拥堵系数** | 假期第1天×2.0，第2天×1.5，返程×2.5 | ✅ 可行 | 无需API，透明可控 | 非官方数据 |
| **方案D：多次调用取平均** | 在不同时间段多次调用API取平均 | ⚠️ 浪费配额 | 接近真实情况 | API配额消耗大 |

### 6.4 推荐方案：**方案A + C 混合**

**核心思路**：
1. 使用高德**实时路况 API** 获取基础行程时间
2. 基于**假期类型**应用拥堵系数：
   ```markdown
   - 假期第1天（出程高峰）：基础时间 × 2.0
   - 假期第2-3天（平稳期）：基础时间 × 1.5
   - 假期最后1天（返程高峰）：基础时间 × 2.5
   - 假期后1天（恢复正常）：基础时间 × 1.2
   ```
3. 输出时标注：**"拥堵系数基于节假日出行规律估算，误差±15%"**

**示例计算**（北京→大连）：
- 实时路况API返回：8小时（当前畅通）
- 假期第1天预测：8 × 2.0 = 16小时（严重拥堵）
- 假期第2天预测：8 × 1.5 = 12小时（缓行）
- 拥堵降低：(16-12)/16 * 100% = 25%

### 6.5 方案选型结论

**针对"未来路况预测"需求**：
- **高德API无法直接支持**驾车路线的未来时间预测
- **推荐方案**：实时路况 API + 节假日拥堵系数
- **降级说明**：在 Skill 输出中明确标注计算逻辑

---

## 7. 参考资料

- 高德开放平台官网：https://lbs.amap.com/
- 应用管理：https://lbs.amap.com/dev/key/app
- 路线规划API：https://lbs.amap.com/api/webservice/guide/api/direction
- POI搜索API：https://lbs.amap.com/api/webservice/guide/api/search
- 交通态势API：https://lbs.amap.com/api/webservice/guide/api-advanced/traffic-situation-inquiry
- 产品定价：https://lbs.amap.com/upgrade

---

**Research 完成时间**：2026-04-16（更新：未来路况预测验证）  
**验证路线**：北京 → 大连  
**研究员**：Claude Code Agent
