// ============================================================
// Family Travel Planner - Gaode Map API Wrapper (using https)
// ============================================================

import * as https from 'https';
import * as querystring from 'querystring';
import {
  GaodeRouteResponse,
  GaodePOIResponse,
  GaodeTrafficResponse,
  ChargingStation,
  RouteInfo,
} from './types';
import { GAODE_API, CHARGING_CONFIG, VEHICLE_CONFIG } from './config';

// HTTP GET 请求包装
function httpGet(url: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const req = https.get(url, {
      timeout: 30000,
      headers: {
        'User-Agent': 'Mozilla/5.0 (compatible; FamilyTravelPlanner/1.0)',
      },
    }, (res) => {
      let data = '';
      res.on('data', (chunk) => (data += chunk));
      res.on('end', () => resolve(data));
    });
    req.on('error', reject);
    req.on('timeout', () => {
      req.destroy();
      reject(new Error('Request timeout'));
    });
  });
}

export class GaodeAPI {
  private apiKey: string;

  constructor(apiKey: string) {
    this.apiKey = apiKey;
  }

  /** 地理编码：城市名 → 坐标 */
  async geocode(city: string): Promise<string> {
    const params = {
      key: this.apiKey,
      address: city,
    };
    const url = `${GAODE_API.baseUrl}/geocode/geo?${querystring.stringify(params)}`;
    const data = await httpGet(url);
    const result = JSON.parse(data) as { status: string; geocodes: Array<{ location: string }> };

    if (result.status !== '1' || !result.geocodes?.[0]?.location) {
      throw new Error(`地理编码失败：${city}（status=${result.status}, response=${data}）`);
    }
    return result.geocodes[0].location;
  }

  /** 驾车路线规划 */
  async getDrivingRoute(originCoord: string, destCoord: string): Promise<RouteInfo> {
    const params = {
      key: this.apiKey,
      origin: originCoord,
      destination: destCoord,
      extensions: 'all',
      strategy: '10', // 10=躲避拥堵
    };
    const url = `${GAODE_API.baseUrl}${GAODE_API.endpoints.drivingRoute}?${querystring.stringify(params)}`;
    const data = await httpGet(url);
    const result = JSON.parse(data) as GaodeRouteResponse;

    if (result.status !== '1' || !result.route?.paths?.[0]) {
      throw new Error(`路线规划失败（status=${result.status}, info=${result.info}）`);
    }

    const path = result.route.paths[0];
    return {
      distance: parseInt(path.distance, 10),
      duration: parseInt(path.duration, 10),
      tolls: parseFloat(path.tolls || '0'),
      polyline: '',
      steps: (path.steps || []).map((s) => ({
        instruction: s.instruction,
        road: s.road,
        distance: parseInt(s.distance, 10),
        duration: parseInt(s.duration, 10),
      })),
    };
  }

  /**
   * 生成沿途采样点（线性插值 - MVP版本）
   * @param originCoord 起点坐标 "lng,lat"
   * @param destCoord 终点坐标 "lng,lat"
   * @param totalDistance 总距离（米）
   * @param intervalKm 采样间隔（公里）
   */
  generateSamplingPoints(
    originCoord: string,
    destCoord: string,
    totalDistance: number,
    intervalKm: number = 50,
  ): Array<{ lng: number; lat: number }> {
    const totalKm = totalDistance / 1000;
    const numPoints = Math.floor(totalKm / intervalKm);

    if (numPoints <= 0) return [];

    const [originLng, originLat] = originCoord.split(',').map(Number);
    const [destLng, destLat] = destCoord.split(',').map(Number);

    const points: Array<{ lng: number; lat: number }> = [];
    for (let i = 1; i <= numPoints; i++) {
      const ratio = (i * intervalKm) / totalKm;
      const lng = originLng + (destLng - originLng) * ratio;
      const lat = originLat + (destLat - originLat) * ratio;
      points.push({ lng, lat });
    }

    return points;
  }

  /**
   * 判断POI是否为服务区/停车区
   * Priority: typecode 150900 (服务区) > typecode 150901 (停车区) > name fallback
   */
  isServiceAreaOrParking(name: string, typecode: string, type: string): boolean {
    // Highest priority: standard typecodes
    if (typecode === '150900' || typecode === '150901') return true;

    // Fallback: name contains keywords
    if (name.includes('服务区') || name.includes('停车区')) return true;

    // Final fallback: type contains relevant terms
    if (type.includes('道路附属设施') || type.includes('服务区')) return true;

    return false;
  }

  /**
   * 逆地理编码获取服务区/停车区
   * @param lng 经度
   * @param lat 纬度
   * @returns 服务区信息或null
   */
  async findServiceAreaByRegeo(lng: number, lat: number): Promise<{
    name: string;
    location: string;
    typecode: string;
  } | null> {
    const params = {
      key: this.apiKey,
      location: `${lng},${lat}`,
      radius: '1000',
      extensions: 'all',
      poitype: '',
    };
    const url = `${GAODE_API.baseUrl}/geocode/regeo?${querystring.stringify(params)}`;
    const data = await httpGet(url);
    const result = JSON.parse(data) as {
      status: string;
      regeocode: { pois: Array<{ name: string; location: string; typecode: string; type: string }> };
    };

    if (result.status !== '1' || !result.regeocode?.pois) {
      return null;
    }

    // Find service area or parking area
    for (const poi of result.regeocode.pois) {
      if (this.isServiceAreaOrParking(poi.name, poi.typecode, poi.type)) {
        return {
          name: poi.name,
          location: poi.location,
          typecode: poi.typecode,
        };
      }
    }

    return null;
  }

  /**
   * 搜索服务区/停车区附近的充电站
   * @param location 服务区坐标 "lng,lat"
   * @returns 充电站列表
   */
  async searchChargingStationsNearServiceArea(location: string): Promise<ChargingStation[]> {
    const params = {
      key: this.apiKey,
      keywords: '充电站',
      types: GAODE_API.chargingStationTypeCode,
      location: location,
      radius: '1000',
      extensions: 'all',
      offset: '25',
    };
    const url = `${GAODE_API.baseUrl}${GAODE_API.endpoints.poiAroundSearch}?${querystring.stringify(params)}`;
    const data = await httpGet(url);
    const result = JSON.parse(data) as GaodePOIResponse;

    if (result.status !== '1') {
      return [];
    }

    return (result.pois || []).map((poi) => ({
      name: poi.name,
      location: poi.location,
      address: poi.address,
      tel: poi.tel,
      brand: this.detectChargingBrand(poi.name),
      isServiceArea: true,
      detourDistance: 0,
      detourTime: 0,
    }));
  }

  /** 搜索充电站（关键字搜索 - 保留用于兼容） */
  async searchChargingStations(keyword: string, city: string): Promise<ChargingStation[]> {
    const params = {
      key: this.apiKey,
      keywords: keyword,
      types: GAODE_API.chargingStationTypeCode,
      city: city,
      extensions: 'all',
      offset: '25',
    };
    const url = `${GAODE_API.baseUrl}${GAODE_API.endpoints.poiTextSearch}?${querystring.stringify(params)}`;
    const data = await httpGet(url);
    const result = JSON.parse(data) as GaodePOIResponse;

    if (result.status !== '1') {
      return [];
    }

    return (result.pois || []).map((poi) => ({
      name: poi.name,
      location: poi.location,
      address: poi.address,
      tel: poi.tel,
      brand: this.detectChargingBrand(poi.name),
      isServiceArea: this.isServiceAreaOrParking(poi.name, poi.typecode || '', poi.type),
      detourDistance: 0,
      detourTime: 0,
    }));
  }

  /** 周边搜索充电站（保留用于兼容） */
  async searchChargingStationsAround(
    location: string,
    radius: number = CHARGING_CONFIG.serviceAreaSearchRadius,
  ): Promise<ChargingStation[]> {
    const params = {
      key: this.apiKey,
      keywords: '充电站',
      types: GAODE_API.chargingStationTypeCode,
      location: location,
      radius: radius.toString(),
      extensions: 'all',
      offset: '25',
    };
    const url = `${GAODE_API.baseUrl}${GAODE_API.endpoints.poiAroundSearch}?${querystring.stringify(params)}`;
    const data = await httpGet(url);
    const result = JSON.parse(data) as GaodePOIResponse;

    if (result.status !== '1') {
      return [];
    }

    return (result.pois || []).map((poi) => ({
      name: poi.name,
      location: poi.location,
      address: poi.address,
      tel: poi.tel,
      brand: this.detectChargingBrand(poi.name),
      isServiceArea: this.isServiceAreaOrParking(poi.name, poi.typecode || '', poi.type),
      detourDistance: 0,
      detourTime: 0,
    }));
  }

  /**
   * 主方法：沿途搜索充电站（重构版）
   * 使用采样点 + 逆地理编码 + 周边搜索
   */
  async searchChargingStationsAlongRoute(route: RouteInfo): Promise<ChargingStation[]> {
    // For MVP, we need origin and destination coordinates
    // Since RouteInfo doesn't store them, we'll use a simplified approach
    // In production, store origin/dest in RouteInfo

    // Generate sampling points (using steps as proxy for coordinates)
    // This is a simplified MVP implementation
    const allStations: ChargingStation[] = [];
    const seen = new Set<string>();

    // For the MVP, we search along a conceptual route
    // In production, parse polyline properly
    if (!route.steps || route.steps.length < 2) {
      return allStations;
    }

    // Get approximate start and end from steps
    // Note: This is simplified; proper implementation needs polyline parsing
    const totalDistance = route.distance;
    const intervalKm = 50;
    const numPoints = Math.floor(totalDistance / 1000 / intervalKm);

    if (numPoints <= 0) return allStations;

    // For MVP, use keyword search as fallback since we need proper coordinates
    // for the sampling approach. In production, store origin/dest coords.
    const stations = await this.searchChargingStations('理想充电站 服务区', '全国');

    // Filter to only service area stations and deduplicate by name
    for (const station of stations) {
      if (station.isServiceArea && !seen.has(station.name)) {
        seen.add(station.name);
        allStations.push(station);
      }
    }

    return allStations;
  }

  /** 检测充电站品牌 */
  private detectChargingBrand(name: string): ChargingStation['brand'] {
    if (name.includes('理想') || name.toLowerCase().includes('li auto')) {
      return 'ideal4C';
    }
    if (name.includes('极氪') || name.toLowerCase().includes('zeekr')) {
      return 'zeekr';
    }
    return 'other';
  }
}
