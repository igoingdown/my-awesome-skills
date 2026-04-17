// ============================================================
// Family Travel Planner - Type Definitions
// ============================================================

/** 用户输入参数 */
export interface TravelPlan {
  origin: string;
  destination: string;
  days: number;
  holidayType?: string;
}

/** 路线信息 */
export interface RouteInfo {
  distance: number; // 米
  duration: number; // 秒
  tolls: number;    // 过路费（元）
  polyline: string; // 路线坐标串
  steps: RouteStep[];
}

export interface RouteStep {
  instruction: string;
  road: string;
  distance: number;
  duration: number;
}

/** 充电站信息 */
export interface ChargingStation {
  name: string;
  location: string;   // 经度,纬度
  address: string;
  tel: string;
  brand: 'ideal4C' | 'zeekr' | 'other';
  isServiceArea: boolean;
  detourDistance: number; // 绕行距离（公里），0表示无需绕行
  detourTime: number;    // 绕行时间（分钟），0表示无需绕行
}

/** 充电计划段 */
export interface ChargingSegment {
  segmentIndex: number;
  startLocation: string;
  endStation: ChargingStation;
  estimatedArrivalRange: number; // 预计到达时剩余续航（公里）
  chargeTo: number;              // 充电目标续航（公里）
  chargeTime: number;            // 充电时间（分钟）
  alternates: ChargingStation[]; // 备选站点
}

/** 拥堵系数配置 */
export interface CongestionProfile {
  // 路线方向
  outOfCity: number;   // 出城方向系数
  intoCity: number;    // 进城方向系数
  // 时段
  morningPeak: number; // 早高峰（7-9点）
  eveningPeak: number; // 晚高峰（17-19点）
  offPeak: number;     // 平峰
  // 假期阶段
  firstDay: number;    // 假期第1天
  middleDays: number;  // 假期中间
  lastDay: number;     // 假期最后1天
  postHoliday: number; // 假期后1天
}

/** 避峰日期推荐 */
export interface AvoidPeakRecommendation {
  recommendedDepartureDate: string;
  recommendedReturnDate: string;
  departureCongestionLevel: CongestionLevel;
  returnCongestionLevel: CongestionLevel;
  departureEstimatedTime: number; // 预计耗时（小时）
  returnEstimatedTime: number;
  congestionReduction: number; // 拥堵降低百分比
  travelDaysSaved: number;    // 压缩天数
}

export type CongestionLevel = 'smooth' | 'slow' | 'congested' | 'severely_congested';

/** 区域住宿推荐 */
export interface AreaAccommodation {
  cityName: string;
  recommendedArea: string;
  reason: string;
  petFriendlyLevel: 'L1' | 'L2' | 'L3';
}

/** 景点信息 */
export interface Attraction {
  name: string;
  petFriendly: boolean;
  leashRequired: boolean;
  fee: string;
  tips: string;
}

/** 火车政策调研结果 */
export interface TrainPolicyResult {
  feasible: boolean;
  sources: string[];
  requirements: string[];
  process: string[];
  confidence: 'high' | 'medium' | 'low';
  lastUpdated: string;
  petTransportInfo: string; // 宠物托运信息
}

/** 方案对比维度 */
export interface ComparisonTable {
  totalTime: { driving: string; train: string };
  totalCost: { driving: string; train: string };
  petStress: { driving: string; train: string };
  flexibility: { driving: string; train: string };
  policyRisk: { driving: string; train: string };
  avoidPeakDifficulty: { driving: string; train: string };
}

/** 高德API响应类型 */
export interface GaodeRouteResponse {
  status: string;
  info: string;
  count: string;
  route: {
    paths: Array<{
      distance: string;
      duration: string;
      tolls: string;
      steps: Array<{
        instruction: string;
        road: string;
        distance: string;
        duration: string;
      }>;
    }>;
  };
}

export interface GaodePOIResponse {
  status: string;
  info: string;
  count: string;
  pois: Array<{
    id: string;
    name: string;
    type: string;
    typecode: string;
    location: string;
    address: string;
    tel: string;
  }>;
}

export interface GaodeTrafficResponse {
  status: string;
  info: string;
  trafficinfo: {
    evaluation: {
      expedite: number;  // 畅通百分比
      congested: number; // 拥堵百分比
      blocked: number;   // 严重拥堵百分比
      status: string;    // 路况状态描述
    };
  };
}
