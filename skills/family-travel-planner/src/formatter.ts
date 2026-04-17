// ============================================================
// Family Travel Planner - Markdown Formatter
// ============================================================

import {
  TravelPlan,
  RouteInfo,
  ChargingSegment,
  AvoidPeakRecommendation,
  AreaAccommodation,
  Attraction,
  TrainPolicyResult,
  ComparisonTable,
} from './types';
import {
  VEHICLE_CONFIG,
  congestionLevelText,
  calculateActualTravelDays,
} from './config';

export function formatTravelPlanMarkdown(params: {
  plan: TravelPlan;
  route: RouteInfo;
  avoidPeak: AvoidPeakRecommendation;
  chargingPlan: ChargingSegment[];
  accommodations: AreaAccommodation[];
  attractions: Attraction[];
  trainPolicy: TrainPolicyResult;
  comparison: ComparisonTable;
}): string {
  const { plan, route, avoidPeak, chargingPlan, accommodations, attractions, trainPolicy, comparison } = params;
  const actualDays = calculateActualTravelDays(plan.days);

  const lines: string[] = [];

  // 标题
  lines.push(`# ${plan.origin} → ${plan.destination} 家庭旅行方案`);
  lines.push('');
  lines.push(`> ${plan.holidayType || ''}假期 | ${plan.days}天 | 实际游玩${actualDays}天 | ${VEHICLE_CONFIG.model} | 携带宠物（约10kg中型犬）`);
  lines.push('');

  // ---- 1. 避峰日期推荐 ----
  lines.push('## 1. 避峰日期推荐');
  lines.push('');
  lines.push(`- **推荐出发日期**：${avoidPeak.recommendedDepartureDate}（${congestionLevelText(avoidPeak.departureCongestionLevel)}）`);
  lines.push(`- **推荐返程日期**：${avoidPeak.recommendedReturnDate}（${congestionLevelText(avoidPeak.returnCongestionLevel)}）`);
  lines.push(`- **预计去程耗时**：${avoidPeak.departureEstimatedTime.toFixed(1)} 小时`);
  lines.push(`- **预计返程耗时**：${avoidPeak.returnEstimatedTime.toFixed(1)} 小时`);
  lines.push(`- **拥堵降低**：${avoidPeak.congestionReduction.toFixed(1)}% ±15%`);
  lines.push(`- **时间牺牲**：${avoidPeak.travelDaysSaved} 天`);
  lines.push('');

  // ---- 2. 自驾方案 ----
  lines.push('## 2. 自驾方案');
  lines.push('');

  // 2.1 路线规划
  lines.push('### 2.1 路线规划');
  lines.push('');
  lines.push(`- **总里程**：${(route.distance / 1000).toFixed(0)} 公里`);
  lines.push(`- **预计耗时**：${(route.duration / 3600).toFixed(1)} 小时（不含充电）`);
  lines.push(`- **过路费**：约 ¥${route.tolls.toFixed(0)}`);
  lines.push('');

  // 2.2 充电计划
  lines.push('### 2.2 充电计划');
  lines.push('');
  lines.push(`> ⚠️ 充电站信息仅供参考，请通过理想APP确认具体站点位置和可用性`);
  lines.push('');

  if (chargingPlan.length === 0) {
    lines.push(`${(route.distance / 1000).toFixed(0)}公里 < ${VEHICLE_CONFIG.fullRange - VEHICLE_CONFIG.minRangeBeforeCharge}公里，无需中途充电`);
    lines.push('');
  } else {
    lines.push('| 序号 | 充电站 | 品牌 | 预计到达续航 | 充电目标 | 充电时间 | 备选站点 |');
    lines.push('|------|--------|------|-------------|---------|---------|----------|');
    for (const seg of chargingPlan) {
      const alternates = seg.alternates
        .map((a) => a.name)
        .join('、') || '无';
      lines.push(
        `| ${seg.segmentIndex} | ${seg.endStation.name} | ${seg.endStation.brand} | ${seg.estimatedArrivalRange}km | ${seg.chargeTo}km | ${seg.chargeTime}min | ${alternates} |`,
      );
    }
    lines.push('');
  }

  // 2.3 区域住宿推荐
  lines.push('### 2.3 区域住宿推荐');
  lines.push('');
  for (const acc of accommodations) {
    lines.push(`**${acc.cityName}**：建议住${acc.recommendedArea}`);
    lines.push(`- 原因：${acc.reason}`);
    lines.push(`- 宠物友好等级：${acc.petFriendlyLevel}`);
    lines.push('');
  }

  // 2.4 景点推荐
  lines.push('### 2.4 宠物友好景点');
  lines.push('');
  if (attractions.length === 0) {
    lines.push('暂无推荐');
  } else {
    for (const attr of attractions) {
      lines.push(`**${attr.name}**`);
      lines.push(`- 宠物友好：${attr.petFriendly ? '是' : '否'} | 需牵引：${attr.leashRequired ? '是' : '否'} | 费用：${attr.fee}`);
      lines.push(`- 提示：${attr.tips}`);
      lines.push('');
    }
  }

  // ---- 3. 火车方案 ----
  lines.push('## 3. 火车方案');
  lines.push('');
  lines.push(`- **可行性**：${trainPolicy.feasible ? '✅ 可行' : '❌ 不可行'}`);
  lines.push(`- **置信度**：${trainPolicy.confidence}`);
  lines.push(`- **信息来源**：${trainPolicy.sources.join('、')}`);
  lines.push(`- **更新时间**：${trainPolicy.lastUpdated}`);
  lines.push('');

  if (trainPolicy.feasible) {
    lines.push('### 乘车要求');
    for (const req of trainPolicy.requirements) {
      lines.push(`- ${req}`);
    }
    lines.push('');
    lines.push('### 办理流程');
    for (let i = 0; i < trainPolicy.process.length; i++) {
      lines.push(`${i + 1}. ${trainPolicy.process[i]}`);
    }
    lines.push('');
  }

  lines.push('### 宠物托运信息');
  lines.push(trainPolicy.petTransportInfo);
  lines.push('');

  // ---- 4. 方案对比 ----
  lines.push('## 4. 方案对比');
  lines.push('');
  lines.push('| 维度 | 自驾 | 火车 |');
  lines.push('|------|------|------|');
  lines.push(`| 总耗时 | ${comparison.totalTime.driving} | ${comparison.totalTime.train} |`);
  lines.push(`| 总成本 | ${comparison.totalCost.driving} | ${comparison.totalCost.train} |`);
  lines.push(`| 宠物压力 | ${comparison.petStress.driving} | ${comparison.petStress.train} |`);
  lines.push(`| 灵活度 | ${comparison.flexibility.driving} | ${comparison.flexibility.train} |`);
  lines.push(`| 政策风险 | ${comparison.policyRisk.driving} | ${comparison.policyRisk.train} |`);
  lines.push(`| 避峰难度 | ${comparison.avoidPeakDifficulty.driving} | ${comparison.avoidPeakDifficulty.train} |`);
  lines.push('');

  // ---- 5. 避峰评估 ----
  lines.push('## 5. 避峰评估');
  lines.push('');
  lines.push('### 理想出行（无避峰）');
  lines.push(`- 假期第1天出发 + 假期最后1天返程`);
  lines.push(`- 预计拥堵指数：高`);
  lines.push(`- 完整游玩时间：${plan.days} 天`);
  lines.push('');
  lines.push('### 避峰出行');
  lines.push(`- ${avoidPeak.recommendedDepartureDate}出发 + ${avoidPeak.recommendedReturnDate}返程`);
  lines.push(`- 预计拥堵降低：${avoidPeak.congestionReduction.toFixed(1)}% ±15%`);
  lines.push(`- 实际游玩时间：${actualDays} 天`);
  lines.push('');
  lines.push(`### 结论`);
  lines.push(`- 拥堵降低 ${avoidPeak.congestionReduction.toFixed(1)}%，时间牺牲 ${avoidPeak.travelDaysSaved} 天`);
  lines.push(`- 数据来源：高德地图交通大数据 + 节假日拥堵系数估算`);
  lines.push(`- 误差范围：±15%（受天气/事故等偶发因素影响）`);
  lines.push('');

  // ---- 6. 待确认事项 ----
  lines.push('## 6. 待确认事项');
  lines.push('');
  lines.push('- [ ] 充电站位置请通过理想APP确认');
  lines.push('- [ ] 住宿请在携程/美团搜索目标区域酒店并电话确认宠物入住政策');
  lines.push('- [ ] 火车宠物政策如有变化，请以12306官网最新公告为准');
  lines.push('');

  return lines.join('\n');
}
