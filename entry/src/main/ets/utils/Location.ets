import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { geoLocationManager } from '@kit.LocationKit';

/**
 * 定位工具（`前后端联调文档-打卡模块.md` 第 2.4 / 7.1 节）
 *
 * 约定：
 *   - 坐标一律 **WGS84**，客户端不做任何坐标转换（GCJ-02 / BD-09 由后端处理）
 *   - 只在点"打卡"那一刻取一次，不做后台持续定位，不上报轨迹
 *   - 8000ms 拿不到就报错，**不要拿上一次的旧坐标凑数**
 */

/** 精确位置权限（必须和 APPROXIMATELY_LOCATION 一起申请，否则系统不弹框） */
const PERM_LOCATION: Permissions = 'ohos.permission.LOCATION';
/** 模糊位置权限，用户只给这个时精度可能上千米，打卡会被后端判"精度太低" */
const PERM_APPROX_LOCATION: Permissions = 'ohos.permission.APPROXIMATELY_LOCATION';

/** 一次定位的结果 */
export interface GeoPoint {
  /** 纬度 -90~90 */
  latitude: number;
  /** 经度 -180~180 */
  longitude: number;
  /** 水平精度半径（米），后端要求 > 0 且 <= 100 */
  accuracy: number;
  /** 系统判定是不是模拟位置 */
  isMock: boolean;
}

/**
 * 申请定位权限。
 *
 * 两个都要：
 *   - APPROXIMATELY_LOCATION：模糊定位，不给连弹框都不出现
 *   - LOCATION：精确定位，只给模糊的精度可能上千米
 *
 * @returns 两个都授予才返回 true
 */
// context是指在哪个app里申请
export async function ensureLocationPermission(context: common.Context): Promise<boolean> {
  if (!canIUse('SystemCapability.Location.Location.Core')) {  // 判断设备支不支持定位能力
    return false;
  }
  try {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();  // ① 创建权限管理器
    const perms: Permissions[] = [PERM_APPROX_LOCATION, PERM_LOCATION];                  // ② 准备要申请的权限列表
    const result = await atManager.requestPermissionsFromUser(context, perms);           // ③ 发起申请，等用户点

    // authResults 里 0 = 已授权，-1 = 拒绝
    const results: number[] = result.authResults;
    if (results.length < 2) {
      return false;
    }
    return results[0] === 0 && results[1] === 0;
  } catch (err) {
    console.error(`申请定位权限失败: ${JSON.stringify(err)}`);
    return false;
  }
}

/**
 * 取一次当前坐标。
 *
 * @param timeoutMs 超时时间，文档要求 8000ms
 * @throws 定位服务没开 / 超时 / 系统报错时抛 Error，message 可以直接展示
 */
export async function getCurrentGeoPoint(timeoutMs: number): Promise<GeoPoint> {
  if (!canIUse('SystemCapability.Location.Location.Core')) {
    throw new Error('当前设备不支持定位功能');
  }
  const request: geoLocationManager.CurrentLocationRequest = {
    // FIRST_FIX：优先拿第一次定位结果，比 ACCURACY 快，打卡场景够用
    priority: geoLocationManager.LocationRequestPriority.FIRST_FIX,  // 快, 模糊定位
    scenario: geoLocationManager.LocationRequestScenario.UNSET,  // "不指定特殊场景"，用默认行为。
    timeoutMs: timeoutMs
  };
  try {
    const location: geoLocationManager.Location = await geoLocationManager.getCurrentLocation(request);
    return {
      latitude: location.latitude,
      longitude: location.longitude,
      accuracy: location.accuracy,
      isMock: location.isFromMock === true
    };
  } catch (err) {
    const code: number = (err as Record<string, Object>).code !== undefined ?
      Number((err as Record<string, Object>).code) : -1;
    console.error(`取定位失败 code=${code}: ${JSON.stringify(err)}`);
    // 3301100 是系统定位服务未开启
    if (code === 3301100) {
      throw new Error('定位服务没打开，请开启系统定位后重试');
    }
    throw new Error('定位失败，请到室外空旷处重试');
  }
}

/** 两点球面距离（Haversine，地球半径 6371000 米），和后端算法保持一致 */
export function haversine(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const earthRadius: number = 6371000;
  const rad: number = Math.PI / 180;
  const dLat: number = (lat2 - lat1) * rad;
  const dLng: number = (lng2 - lng1) * rad;
  const a: number = Math.pow(Math.sin(dLat / 2), 2) +
    Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.pow(Math.sin(dLng / 2), 2);
  return 2 * earthRadius * Math.asin(Math.sqrt(a));
}

/** 坐标是否合法（后端也校验同一套范围） */
export function isValidCoordinate(latitude: number, longitude: number): boolean {
  if (isNaN(latitude) || isNaN(longitude)) {
    return false;
  }
  return latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180;
}

/** 距离显示：小于 1 公里显示米，否则显示公里 */
export function formatDistance(meters: number): string {
  if (meters < 1000) {
    return `${meters.toFixed(0)} 米`;
  }
  return `${(meters / 1000).toFixed(2)} 公里`;
}

/** 坐标显示成 "31.230416, 121.473701" */
export function formatLatLng(latitude: number, longitude: number): string {
  return `${latitude.toFixed(6)}, ${longitude.toFixed(6)}`;
}


/**
 * 地址搜索结果。
 *
 * 用途：管理员设打卡点时不用手输经纬度——打字搜「天府三街地铁站」，
 * 从结果里点一个，纬度/经度/地点名一次填好。
 */
export interface GeoPlace {
  /** 地址描述，例如「四川省成都市武侯区天府三街」 */
  name: string;
  latitude: number;
  longitude: number;
}

/** 设备有没有地理编码能力（没网络 / 系统没这个服务时会返回 false） */
export function isGeocoderReady(): boolean {
  try {
    if (!canIUse('SystemCapability.Location.Location.Geocoder')) {
      return false;
    }
    return geoLocationManager.isGeocoderAvailable();
  } catch (err) {
    console.warn(`探测地理编码能力失败: ${JSON.stringify(err)}`);
    return false;
  }
}

/**
 * 正向地理编码：地址文字 → 坐标列表。
 *
 * 不需要定位权限，走系统服务联网查。
 * 坐标系：华为官方场景化文档明确写「Location Kit 返回的位置都是基于 WGS84 坐标系的」，
 * 所以这里拿到的就是 GPS 坐标，直接存进任务表，**不要**再套 GCJ-02 转换
 * （只有往国内地图上画点时才需要 WGS84 → GCJ-02，那是 Map Kit 的事）。
 *
 * @param description 地址/地名关键词
 * @param near 可选：优先返回这附近的结果（用当前坐标缩小范围）
 * @throws 不支持 / 没网 / 没结果时抛 Error，message 可直接展示
 */
export async function geocodeAddress(description: string, near?: GeoPoint): Promise<GeoPlace[]> {
  const keyword: string = description.trim();
  if (keyword.length === 0) {
    throw new Error('请输入要搜索的地址');
  }
  if (!isGeocoderReady()) {
    throw new Error('当前设备不支持地址搜索');
  }
  const request: geoLocationManager.GeoCodeRequest = {
    description: keyword,
    locale: 'zh',
    maxItems: 8
  };
  if (near !== undefined) {
    // 以当前点为中心 ±0.5 度（约 50 公里）内优先，避免搜出别的城市同名地点
    request.minLatitude = near.latitude - 0.5;
    request.maxLatitude = near.latitude + 0.5;
    request.minLongitude = near.longitude - 0.5;
    request.maxLongitude = near.longitude + 0.5;
  }
  try {
    const addresses: geoLocationManager.GeoAddress[] =
      await geoLocationManager.getAddressesFromLocationName(request);
    const places: GeoPlace[] = [];
    for (let i = 0; i < addresses.length; i++) {
      const address: geoLocationManager.GeoAddress = addresses[i];
      if (address.latitude === undefined || address.longitude === undefined) {
        continue;
      }
      const name: string = address.placeName !== undefined && address.placeName.length > 0 ?
        address.placeName : keyword;
      // 系统给的已经是 WGS84，原样收下
      places.push({ name: name, latitude: address.latitude, longitude: address.longitude });
    }
    if (places.length === 0) {
      throw new Error('没搜到这个地址，换个关键词试试（例如只填路名/大厦名）');
    }
    return places;
  } catch (err) {
    if (err instanceof Error && err.message.indexOf('没搜到') >= 0) {
      throw err;
    }
    console.error(`地址搜索失败: ${JSON.stringify(err)}`);
    throw new Error('地址搜索失败，请联网后重试，或手动填经纬度');
  }
}

/**
 * 反向地理编码：坐标 → 地址文字。
 *
 * "用当前位置"之后自动把地点名填上，省得管理员自己敲。
 * 失败不抛异常，返回空串（地址只是给人看的，不能因为它挡住建任务）。
 */
export async function reverseGeocode(point: GeoPoint): Promise<string> {
  if (!isGeocoderReady()) {
    return '';
  }
  const request: geoLocationManager.ReverseGeoCodeRequest = {
    latitude: point.latitude,
    longitude: point.longitude,
    locale: 'zh',
    maxItems: 1
  };
  try {
    const addresses: geoLocationManager.GeoAddress[] =
      await geoLocationManager.getAddressesFromLocation(request);
    if (addresses.length === 0) {
      return '';
    }
    const address: geoLocationManager.GeoAddress = addresses[0];
    return address.placeName !== undefined ? address.placeName : '';
  } catch (err) {
    console.warn(`反查地址失败: ${JSON.stringify(err)}`);
    return '';
  }
}
