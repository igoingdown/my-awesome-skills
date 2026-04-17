// ============================================================
// Family Travel Planner - Congestion Coefficient Configuration
// ============================================================
// 拥堵系数与路线方向、时段、假期阶段关联
// 用户可通过修改此文件调整系数

import { CongestionProfile, CongestionLevel } from './types';

/** 默认拥堵系数配置 */
export const DEFAULT_CONGESTION_PROFILE: CongestionProfile = {
  // 路线方向（出城通常比进城更堵，因为假期集中出行）
  outOfCity: 2.0,
  intoCity: 1.8,

  // 时段
  morningPeak: 1.8,  // 早高峰（7-9点）
  eveningPeak: 1.6,  // 晚高峰（17-19点）
  offPeak: 1.2,      // 平峰

  // 假期阶段
  firstDay: 2.5,     // 假期第1天（出程高峰）
  middleDays: 1.3,   // 假期中间（相对平稳）
  lastDay: 2.2,      // 假期最后1天（返程高峰）
  postHoliday: 1.1,  // 假期后1天（基本恢复）
};

/**
 * 根据路线方向、时段、假期阶段计算综合拥堵系数
 *
 * 公式：综合系数 = 方向系数 × 时段系数 × 假期阶段系数 / 基准值
 * 基准值 = 1.0（即三个系数都是1.0时，拥堵系数为1.0，表示无额外拥堵）
 */
export function calculateCongestionCoefficient(params: {
  direction: 'out' | 'in';
  timeOfDay: 'morningPeak' | 'eveningPeak' | 'offPeak';
  holidayPhase: 'firstDay' | 'middleDays' | 'lastDay' | 'postHoliday';
  profile?: CongestionProfile;
}): number {
  const p = params.profile ?? DEFAULT_CONGESTION_PROFILE;

  const directionCoeff = params.direction === 'out' ? p.outOfCity : p.intoCity;
  const timeCoeff =
    params.timeOfDay === 'morningPeak'
      ? p.morningPeak
      : params.timeOfDay === 'eveningPeak'
        ? p.eveningPeak
        : p.offPeak;
  const holidayCoeff =
    params.holidayPhase === 'firstDay'
      ? p.firstDay
      : params.holidayPhase === 'middleDays'
        ? p.middleDays
        : params.holidayPhase === 'lastDay'
          ? p.lastDay
          : p.postHoliday;

  // 综合系数：三个维度相乘，除以基准1.0²（避免过度放大）
  return Math.round((directionCoeff * timeCoeff * holidayCoeff) / 2.0 * 100) / 100;
}

/** 根据拥堵系数判断拥堵等级 */
export function getCongestionLevel(coefficient: number): CongestionLevel {
  if (coefficient < 1.5) return 'smooth';
  if (coefficient < 2.0) return 'slow';
  if (coefficient < 2.5) return 'congested';
  return 'severely_congested';
}

/** 拥堵等级中文描述 */
export function congestionLevelText(level: CongestionLevel): string {
  const map: Record<CongestionLevel, string> = {
    smooth: '畅通',
    slow: '缓行',
    congested: '拥堵',
    severely_congested: '严重拥堵',
  };
  return map[level];
}

// ============================================================
// 车辆配置（硬编码）
// ============================================================

export const VEHICLE_CONFIG = {
  model: 'Tesla Model Y',
  fullRange: 480,        // 满电续航（公里）
  minRangeBeforeCharge: 80,  // 必须补电的剩余续航
  chargeTarget: 330,     // 充电目标续航
  chargeTimeMinutes: 30, // 充电时间（分钟）
} as const;

// ============================================================
// 充电站配置（硬编码）
// ============================================================

export const CHARGING_CONFIG = {
  preferredBrands: ['ideal4C', 'zeekr'] as const,
  minPowerKW: 480,        // 最低功率要求
  excludePowerBelow: 120, // 排除低于此功率的桩
  maxDetourDistance: 10,   // 绕行最大距离（公里）
  maxDetourTime: 10,      // 绕行最大时间（分钟）
  minAlternateStations: 2, // 最少备选站点数
  serviceAreaSearchRadius: 5000,  // 服务区搜索半径（米）
  citySearchRadius: 10000,        // 城市内搜索半径（米）
} as const;

// ============================================================
// 高德API配置
// ============================================================

export const GAODE_API = {
  baseUrl: 'https://restapi.amap.com/v3',
  chargingStationTypeCode: '160100', // 充电站POI类型码
  endpoints: {
    drivingRoute: '/direction/driving',
    poiTextSearch: '/place/text',
    poiAroundSearch: '/place/around',
    trafficRoad: '/traffic/status/road',
    trafficCircle: '/traffic/status/circle',
  },
} as const;

// ============================================================
// 假期时间压缩配置
// ============================================================

export const TIME_COMPRESSION: Record<number, number> = {
  3: 0, // 3天假期不压缩
  5: 2, // 5天假期最多压缩2天
  7: 2, // 7天假期最多压缩2天
};

/** 根据假期天数计算实际游玩天数 */
export function calculateActualTravelDays(totalDays: number): number {
  const compression = TIME_COMPRESSION[totalDays] ?? Math.min(2, Math.floor(totalDays * 0.3));
  return totalDays - compression;
}

/** 根据假期天数和假期类型推荐避峰日期偏移 */
export function getAvoidPeakOffset(totalDays: number): {
  departureOffset: number; // 出发日期偏移（0=假期第1天）
  returnOffset: number;    // 返程日期偏移（0=假期最后1天）
} {
  const compression = TIME_COMPRESSION[totalDays] ?? 0;
  if (compression === 0) {
    return { departureOffset: 0, returnOffset: 0 };
  }
  // 节后1天出发，节前1天返程
  return {
    departureOffset: 1,
    returnOffset: 1,
  };
}
