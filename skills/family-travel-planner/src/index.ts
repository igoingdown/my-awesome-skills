// ============================================================
// Family Travel Planner - Main Entry
// ============================================================

import { readFileSync } from 'fs';
import { resolve } from 'path';
import { GaodeAPI } from './gaode';
import { formatTravelPlanMarkdown } from './formatter';
import {
  TravelPlan,
  ChargingSegment,
  AvoidPeakRecommendation,
  AreaAccommodation,
  Attraction,
  TrainPolicyResult,
  ComparisonTable,
  RouteInfo,
} from './types';
import {
  VEHICLE_CONFIG,
  CHARGING_CONFIG,
  calculateCongestionCoefficient,
  getCongestionLevel,
  calculateActualTravelDays,
  getAvoidPeakOffset,
  DEFAULT_CONGESTION_PROFILE,
} from './config';

// ----------------------------------------------------------
// CLI 参数解析
// ----------------------------------------------------------

function parseArgs(argv: string[]): TravelPlan {
  const args = argv.slice(2);
  const plan: Record<string, string> = {};

  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) {
      const key = args[i].slice(2);
      const value = args[i + 1];
      if (value && !value.startsWith('--')) {
        plan[key] = value;
        i++;
      }
    }
  }

  if (!plan.origin || !plan.destination || !plan.days) {
    console.error('用法: node dist/index.js --origin <起点> --destination <终点> --days <天数> [--holiday <假期类型>]');
    console.error('');
    console.error('示例: node dist/index.js --origin 北京 --destination 大连 --days 5 --holiday 五一');
    process.exit(1);
  }

  return {
    origin: plan.origin,
    destination: plan.destination,
    days: parseInt(plan.days, 10),
    holidayType: plan.holiday || undefined,
  };
}

// ----------------------------------------------------------
// 环境变量读取
// ----------------------------------------------------------

function getApiKey(): string {
  // 1. 从环境变量读取
  let apiKey = process.env.GAODE_API_KEY;

  // 2. 从 .env 文件读取
  if (!apiKey) {
    try {
      const envPath = resolve(__dirname, '..', '.env');
      const envContent = readFileSync(envPath, 'utf-8');
      const match = envContent.match(/GAODE_API_KEY\s*=\s*(.+)/);
      if (match) {
        apiKey = match[1].trim().replace(/^["']|["']$/g, '');
      }
    } catch {
      // .env 文件不存在
    }
  }

  if (!apiKey || apiKey === 'your_api_key_here') {
    console.error('错误：未配置高德地图 API Key');
    console.error('');
    console.error('请执行以下步骤：');
    console.error('1. cp .env.example .env');
    console.error('2. 编辑 .env 文件，填入你的 GAODE_API_KEY');
    console.error('3. 重新运行此脚本');
    console.error('');
    console.error('API Key 申请地址：https://lbs.amap.com/dev/key/app');
    process.exit(1);
  }

  return apiKey;
}

// ----------------------------------------------------------
// 核心逻辑
// ----------------------------------------------------------

async function generateTravelPlan(plan: TravelPlan): Promise<string> {
  const apiKey = getApiKey();
  const gaode = new GaodeAPI(apiKey);

  console.error(`[INFO] 正在规划 ${plan.origin} → ${plan.destination} 的旅行方案...`);

  // 1. 地理编码
  console.error('[INFO] 正在获取坐标...');
  const originCoord = await gaode.geocode(plan.origin);
  const destCoord = await gaode.geocode(plan.destination);

  // 2. 路线规划
  console.error('[INFO] 正在规划路线...');
  const route = await gaode.getDrivingRoute(originCoord, destCoord);

  // 3. 避峰日期推荐
  console.error('[INFO] 正在计算避峰方案...');
  const avoidPeak = calculateAvoidPeakRecommendation(plan, route);

  // 4. 充电计划
  console.error('[INFO] 正在搜索充电站...');
  const chargingPlan = await buildChargingPlan(gaode, route, plan);

  // 5. 区域住宿推荐
  console.error('[INFO] 正在推荐住宿区域...');
  const accommodations = recommendAccommodations(plan, route);

  // 6. 景点推荐
  console.error('[INFO] 正在推荐景点...');
  const attractions = recommendAttractions(plan);

  // 7. 火车政策
  console.error('[INFO] 正在调研火车宠物政策...');
  const trainPolicy = await researchTrainPolicy(plan);

  // 8. 方案对比
  const comparison = buildComparisonTable(plan, route, trainPolicy);

  // 9. 格式化输出
  return formatTravelPlanMarkdown({
    plan,
    route,
    avoidPeak,
    chargingPlan,
    accommodations,
    attractions,
    trainPolicy,
    comparison,
  });
}

// ----------------------------------------------------------
// 避峰日期计算
// ----------------------------------------------------------

function calculateAvoidPeakRecommendation(
  plan: TravelPlan,
  route: RouteInfo,
): AvoidPeakRecommendation {
  const offset = getAvoidPeakOffset(plan.days);
  const actualDays = calculateActualTravelDays(plan.days);

  // 计算假期日期（简化：以2026年五一为例）
  const holidayDates = getHolidayDates(plan.holidayType);
  const departureDate = holidayDates.start.plusDays(offset.departureOffset);
  const returnDate = holidayDates.end.minusDays(offset.returnOffset);

  // 去程：出城方向 + 早高峰 + 假期阶段
  const departureCoeff = calculateCongestionCoefficient({
    direction: 'out',
    timeOfDay: 'morningPeak',
    holidayPhase: offset.departureOffset === 0 ? 'firstDay' : 'middleDays',
  });

  // 返程：进城方向 + 晚高峰 + 假期阶段
  const returnCoeff = calculateCongestionCoefficient({
    direction: 'in',
    timeOfDay: 'eveningPeak',
    holidayPhase: offset.returnOffset === 0 ? 'lastDay' : 'middleDays',
  });

  // 对比：不避峰时的系数
  const peakDepartureCoeff = calculateCongestionCoefficient({
    direction: 'out',
    timeOfDay: 'morningPeak',
    holidayPhase: 'firstDay',
  });
  const peakReturnCoeff = calculateCongestionCoefficient({
    direction: 'in',
    timeOfDay: 'eveningPeak',
    holidayPhase: 'lastDay',
  });

  const baseDurationHours = route.duration / 3600;
  const departureEstimatedTime = baseDurationHours * departureCoeff;
  const returnEstimatedTime = baseDurationHours * returnCoeff;
  const peakDepartureTime = baseDurationHours * peakDepartureCoeff;
  const peakReturnTime = baseDurationHours * peakReturnCoeff;

  const congestionReduction =
    ((peakDepartureTime + peakReturnTime) - (departureEstimatedTime + returnEstimatedTime)) /
    (peakDepartureTime + peakReturnTime) * 100;

  return {
    recommendedDepartureDate: departureDate.format(),
    recommendedReturnDate: returnDate.format(),
    departureCongestionLevel: getCongestionLevel(departureCoeff),
    returnCongestionLevel: getCongestionLevel(returnCoeff),
    departureEstimatedTime,
    returnEstimatedTime,
    congestionReduction: Math.max(0, congestionReduction),
    travelDaysSaved: plan.days - actualDays,
  };
}

/** 简单日期工具 */
interface SimpleDate {
  year: number;
  month: number;
  day: number;
  plusDays(n: number): SimpleDate;
  minusDays(n: number): SimpleDate;
  format(): string;
}

function makeDate(year: number, month: number, day: number): SimpleDate {
  return {
    year, month, day,
    plusDays(n: number): SimpleDate {
      const d = new Date(year, month - 1, day + n);
      return makeDate(d.getFullYear(), d.getMonth() + 1, d.getDate());
    },
    minusDays(n: number): SimpleDate {
      return this.plusDays(-n);
    },
    format(): string {
      return `${year}年${month}月${day}日`;
    },
  };
}

function getHolidayDates(holidayType?: string): { start: SimpleDate; end: SimpleDate } {
  const holidays: Record<string, { start: SimpleDate; end: SimpleDate }> = {
    '五一': { start: makeDate(2026, 5, 1), end: makeDate(2026, 5, 5) },
    '国庆': { start: makeDate(2026, 10, 1), end: makeDate(2026, 10, 7) },
    '春节': { start: makeDate(2027, 1, 25), end: makeDate(2027, 1, 31) },
    '清明': { start: makeDate(2026, 4, 4), end: makeDate(2026, 4, 6) },
    '中秋': { start: makeDate(2026, 9, 25), end: makeDate(2026, 9, 27) },
  };
  return holidays[holidayType || '五一'] || holidays['五一'];
}

// ----------------------------------------------------------
// 充电计划
// ----------------------------------------------------------

async function buildChargingPlan(
  gaode: GaodeAPI,
  route: RouteInfo,
  plan: TravelPlan,
): Promise<ChargingSegment[]> {
  const fullRange = VEHICLE_CONFIG.fullRange;
  const minRange = VEHICLE_CONFIG.minRangeBeforeCharge;
  const maxSegmentKm = fullRange - minRange; // 每段最大行驶公里数
  const totalKm = route.distance / 1000;

  // 如果总里程在单次续航内，无需充电
  if (totalKm <= maxSegmentKm) {
    return [];
  }

  const segments: ChargingSegment[] = [];
  const numCharges = Math.ceil(totalKm / maxSegmentKm);

  // 搜索沿途充电站
  let stations = await gaode.searchChargingStations('理想充电站 服务区', plan.destination);

  // 如果服务区搜索结果不够，搜索城市内
  if (stations.length < numCharges * 2) {
    const cityStations = await gaode.searchChargingStations('理想充电站', plan.destination);
    stations = [...stations, ...cityStations.filter(
      (s) => !stations.find((e) => e.name === s.name),
    )];
  }

  // 优先选择服务区内理想4C
  const sortedStations = stations.sort((a, b) => {
    if (a.isServiceArea && !b.isServiceArea) return -1;
    if (!a.isServiceArea && b.isServiceArea) return 1;
    if (a.brand === 'ideal4C' && b.brand !== 'ideal4C') return -1;
    if (a.brand !== 'ideal4C' && b.brand === 'ideal4C') return 1;
    return 0;
  });

  for (let i = 0; i < numCharges; i++) {
    const mainStation = sortedStations[i % sortedStations.length] || {
      name: `第${i + 1}个充电点（待确认）`,
      location: '',
      address: '',
      tel: '',
      brand: 'other' as const,
      isServiceArea: false,
      detourDistance: 0,
      detourTime: 0,
    };

    const alternates = sortedStations
      .filter((s) => s.name !== mainStation.name)
      .slice(0, CHARGING_CONFIG.minAlternateStations);

    segments.push({
      segmentIndex: i + 1,
      startLocation: i === 0 ? plan.origin : sortedStations[(i - 1) % sortedStations.length]?.name || `充电点${i}`,
      endStation: mainStation,
      estimatedArrivalRange: minRange,
      chargeTo: VEHICLE_CONFIG.chargeTarget,
      chargeTime: VEHICLE_CONFIG.chargeTimeMinutes,
      alternates,
    });
  }

  return segments;
}

// ----------------------------------------------------------
// 区域住宿推荐
// ----------------------------------------------------------

function recommendAccommodations(
  plan: TravelPlan,
  route: RouteInfo,
): AreaAccommodation[] {
  // 根据路线推荐沿途和目的地的住宿区域
  const accommodations: AreaAccommodation[] = [];

  // 目的地住宿
  accommodations.push({
    cityName: plan.destination,
    recommendedArea: getRecommendedArea(plan.destination),
    reason: '该区域宠物友好酒店较多，交通便利，适合带犬出行',
    petFriendlyLevel: 'L1',
  });

  // 如果路途超过6小时，推荐中途住宿
  if (route.duration > 6 * 3600) {
    const midpointCity = getMidpointCity(plan.origin, plan.destination);
    accommodations.unshift({
      cityName: midpointCity,
      recommendedArea: getRecommendedArea(midpointCity),
      reason: '长途驾驶中途休息，该区域有宠物友好住宿',
      petFriendlyLevel: 'L1',
    });
  }

  return accommodations;
}

function getRecommendedArea(city: string): string {
  const areaMap: Record<string, string> = {
    '大连': '中山区星海广场/东港商务区附近',
    '锦州': '古塔区市中心附近',
    '盘锦': '兴隆台区市中心附近',
    '青岛': '市南区栈桥/八大关附近',
    '烟台': '芝罘区滨海广场附近',
    '威海': '环翠区国际海水浴场附近',
    '秦皇岛': '海港区北戴河附近',
  };
  return areaMap[city] || '市中心/火车站附近';
}

function getMidpointCity(origin: string, destination: string): string {
  const midpoints: Record<string, Record<string, string>> = {
    '北京': {
      '大连': '锦州',
      '青岛': '济南',
      '烟台': '潍坊',
      '威海': '烟台',
    },
  };
  return midpoints[origin]?.[destination] || '路线中途城市';
}

// ----------------------------------------------------------
// 景点推荐
// ----------------------------------------------------------

function recommendAttractions(plan: TravelPlan): Attraction[] {
  // 基于目的地的宠物友好景点推荐
  const attractionsMap: Record<string, Attraction[]> = {
    '大连': [
      {
        name: '星海广场',
        petFriendly: true,
        leashRequired: true,
        fee: '免费',
        tips: '广场很大，适合遛狗，注意海风较大',
      },
      {
        name: '滨海路',
        petFriendly: true,
        leashRequired: true,
        fee: '免费',
        tips: '沿海步道，风景优美，适合带狗散步',
      },
      {
        name: '金石滩地质公园',
        petFriendly: true,
        leashRequired: true,
        fee: '景区门票',
        tips: '户外区域可带宠物，室内展馆不可入内',
      },
    ],
  };

  return attractionsMap[plan.destination] || [
    {
      name: `${plan.destination}城市公园`,
      petFriendly: true,
      leashRequired: true,
      fee: '免费',
      tips: '建议到达后在美团/携程搜索"宠物友好景点"获取最新信息',
    },
    {
      name: `${plan.destination}滨海步道/湖边步道`,
      petFriendly: true,
      leashRequired: true,
      fee: '免费',
      tips: '户外步道通常允许携带宠物',
    },
    {
      name: `${plan.destination}郊野公园`,
      petFriendly: true,
      leashRequired: true,
      fee: '门票',
      tips: '郊野公园通常宠物友好，建议提前电话确认',
    },
  ];
}

// ----------------------------------------------------------
// 火车政策调研
// ----------------------------------------------------------

async function researchTrainPolicy(plan: TravelPlan): Promise<TrainPolicyResult> {
  // 由于此脚本在 OpenClaw/Agent 环境中执行，
  // 火车政策需要通过 WebSearch 搜索
  // 这里输出提示信息，由 Agent 补充搜索结果
  return {
    feasible: false,
    sources: ['需通过 Agent WebSearch 搜索最新政策'],
    requirements: [
      '请在 Agent 中搜索：' + plan.origin + ' ' + plan.destination + ' 宠物乘车 ' + new Date().getFullYear(),
      '请同时搜索：宠物托运 铁路 最新政策',
    ],
    process: ['待搜索后补充'],
    confidence: 'low',
    lastUpdated: new Date().toISOString().split('T')[0],
    petTransportInfo: '需搜索最新铁路宠物托运政策，当前信息可能已过时',
  };
}

// ----------------------------------------------------------
// 方案对比表
// ----------------------------------------------------------

function buildComparisonTable(
  plan: TravelPlan,
  route: RouteInfo,
  trainPolicy: TrainPolicyResult,
): ComparisonTable {
  const drivingHours = (route.duration / 3600).toFixed(1);
  const drivingCost = route.tolls + Math.ceil(route.distance / 1000 / 15) * 1.5; // 电费估算

  return {
    totalTime: {
      driving: `${drivingHours}小时（含充电）`,
      train: trainPolicy.feasible ? '约4-6小时' : '暂不可行',
    },
    totalCost: {
      driving: `约¥${drivingCost.toFixed(0)}（过路费+电费）`,
      train: trainPolicy.feasible ? '约¥300-500（车票+托运费）' : '-',
    },
    petStress: {
      driving: '低（车内可控）',
      train: trainPolicy.feasible ? '中（笼具+车站流程）' : '-',
    },
    flexibility: {
      driving: '高（目的地自由行动）',
      train: trainPolicy.feasible ? '低（需当地交通）' : '-',
    },
    policyRisk: {
      driving: '低',
      train: trainPolicy.feasible ? '中（政策可能变化）' : '-',
    },
    avoidPeakDifficulty: {
      driving: '中（需规划）',
      train: trainPolicy.feasible ? '低（车次固定）' : '-',
    },
  };
}

// ----------------------------------------------------------
// 主入口
// ----------------------------------------------------------

async function main(): Promise<void> {
  const plan = parseArgs(process.argv);

  try {
    const markdown = await generateTravelPlan(plan);
    console.log(markdown);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`[ERROR] ${message}`);
    process.exit(1);
  }
}

main();
