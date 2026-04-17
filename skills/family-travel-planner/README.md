# Family Travel Planner

带宠物家庭自驾旅行规划 Skill，生成完整的宠物友好旅行方案。

## 快速开始

```bash
# 1. 安装依赖
cd skills/family-travel-planner
npm install

# 2. 编译 TypeScript
npm run build

# 3. 配置 API Key
cp .env.example .env
# 编辑 .env，填入 GAODE_API_KEY

# 4. 执行
npm start -- --origin 北京 --destination 大连 --days 5 --holiday 五一
```

## 高德地图 API Key 申请

1. 访问 https://lbs.amap.com/
2. 注册账号并完成开发者认证（个人/企业）
3. 进入应用管理：https://lbs.amap.com/dev/key/app
4. 创建新应用，选择 **Web服务** 类型
5. 获取 API Key

### 配额说明

| 服务 | 个人用户免费额度 |
|------|-----------------|
| 路线规划 | 15万次/月 |
| POI搜索 | 5千次/月 |
| 交通态势 | 需单独确认 |

## 参数说明

| 参数 | 必填 | 说明 |
|------|------|------|
| `--origin` | 是 | 出发城市 |
| `--destination` | 是 | 目的城市 |
| `--days` | 是 | 假期总天数 |
| `--holiday` | 否 | 假期类型（五一/国庆/春节等） |

## 未来优化项

### Haversine 球面距离计算

当前MVP版本使用线性插值计算采样点，对于<1000km的自驾路线误差<0.1%。

对于>3000km的长途旅行，建议升级为Haversine公式计算球面距离，以提高采样点精度。

参考实现：
```typescript
// Haversine formula implementation
function haversineDistance(p1: {lat: number, lng: number}, p2: {lat: number, lng: number}): number {
  const R = 6371; // Earth radius in km
  const dLat = (p2.lat - p1.lat) * Math.PI / 180;
  const dLon = (p2.lng - p1.lng) * Math.PI / 180;
  const a = Math.sin(dLat/2) * Math.sin(dLat/2) +
            Math.cos(p1.lat * Math.PI / 180) * Math.cos(p2.lat * Math.PI / 180) *
            Math.sin(dLon/2) * Math.sin(dLon/2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));
  return R * c;
}
```

### 完整实现路线沿途充电站搜索

当前版本使用关键字搜索作为MVP实现。生产环境应：
1. 解析路线规划API返回的polyline坐标串
2. 沿路线每隔50km生成采样点
3. 对每个采样点执行逆地理编码
4. 过滤服务区/停车区POI（typecode=150900/150901）
5. 对服务区执行周边充电站搜索

## 部署到 OpenClaw

```bash
# 复制到全局 Skills 目录
cp -r skills/family-travel-planner ~/.agents/skills/

# 在 .env 中配置 API Key
cd ~/.agents/skills/family-travel-planner
cp .env.example .env
# 编辑 .env

# 编译
npm install && npm run build

# 验证
openclaw skills list | grep family-travel-planner
```
