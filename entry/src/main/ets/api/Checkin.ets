import { request, MultipartField, MultipartFile } from '../utils/HttpUtil';

/**
 * 声纹 + 位置打卡接口（`前后端联调文档-打卡模块.md` v1.0，2026-10-29）
 *
 *   GET  /checkin/voice-challenge?taskId=   申请 4 位挑战码（60 秒有效）
 *   POST /checkin/voice                     上传音频 + 坐标，声纹和位置都过才算打卡
 *
 * 三个必须记住的点：
 *   1. 打卡是 **multipart/form-data**，不是 JSON
 *   2. 位置按任务可选：任务没坐标就不传 latitude/longitude/accuracy
 *   3. 只有 401 才清 token；410/422/429 都是"重新申请挑战码 / 重新录"，别踢下线
 */

/** 挑战码 GET /checkin/voice-challenge */
export interface VoiceChallenge {
  taskId: number;
  /** 提交时原样带回，60 秒有效，同一任务重新申请会让旧码作废 */
  nonce: string;
  /** 4 位数字，相邻两位不会相同 */
  digits: string;
  /** 过期时间（服务器本地时间，不带时区） */
  expireAt: string;
  /** 有效期秒数，固定 60 */
  ttlSeconds: number;
  /** 给用户念的提示，例如"请匀速朗读：3 8 1 5，每个数字之间停顿约 0.2 秒" */
  prompt: string;
}

/** 打卡结果 POST /checkin/voice */
export interface VoiceCheckinResult {
  recordId: number;
  taskId: number;
  checkType: string;
  /** 服务器本地时间，不带时区 */
  checkedAt: string;
  /** 与打卡点距离（米）；不限位置的任务为 null */
  distanceM: number | null;
  /** 允许半径（米）；不限位置的任务为 null */
  radiusM: number | null;
  /** 是否通过了距离校验；不限位置任务为 false */
  locationVerified: boolean;
  accuracy: number | null;
  isMock: boolean;
  /** 声纹平均分 0~1 */
  avgScore: number;
  /** 声纹最低分 0~1 */
  minScore: number;
  /** 后端识别出来的数字，正常应与挑战码一致 */
  detectedDigits: string;
}

/** 提交打卡的参数 */
export interface VoiceCheckinParams {
  taskId: number;
  nonce: string;
  digits: string;
  /** 16kHz / 16bit / 单声道 WAV 的完整字节（含 44 字节头），3~6 秒 */
  wav: ArrayBuffer;
  /** 任务有打卡点时才传，三个一起传 */
  latitude?: number;
  longitude?: number;
  accuracy?: number;
  /** 系统判定为模拟位置时传 true，任务有打卡点会被后端直接拒绝 */
  isMock?: boolean;
}

/**
 * 申请挑战码。
 *
 * 失败里最容易踩的：409 "请先完成声纹注册"（10 个数字没录齐）、
 * 409 "本次考勤已完成打卡"、429 一分钟内超过 5 次。
 */
export function getVoiceChallenge(taskId: number): Promise<VoiceChallenge> {
  return request.get<VoiceChallenge>(`/checkin/voice-challenge?taskId=${taskId}`, undefined,
    { timeout: 15000 });
}

/**
 * 提交音频 + 坐标打卡。
 *
 * 位置失败（400）不消耗 nonce 的失败次数，用户可以走到范围内用同一个 nonce 重提；
 * 音频/声纹失败（422）会消耗次数，同一 nonce 最多 3 次，第 4 次返回 429。
 */
export function submitVoiceCheckin(params: VoiceCheckinParams): Promise<VoiceCheckinResult> {
  const fields: MultipartField[] = [
    { fieldName: 'taskId', value: `${params.taskId}` },
    { fieldName: 'nonce', value: params.nonce },
    { fieldName: 'digits', value: params.digits }
  ];
  // 不限位置的任务：后端根本不要坐标，别传空串，会触发"坐标不合法"
  if (params.latitude !== undefined && params.longitude !== undefined &&
    params.accuracy !== undefined) {
    fields.push({ fieldName: 'latitude', value: `${params.latitude}` });
    fields.push({ fieldName: 'longitude', value: `${params.longitude}` });
    fields.push({ fieldName: 'accuracy', value: `${params.accuracy}` });
    fields.push({ fieldName: 'isMock', value: params.isMock === true ? 'true' : 'false' });
  }
  const files: MultipartFile[] = [{
    fieldName: 'audio',
    fileName: 'checkin.wav',
    contentType: 'audio/wav',
    data: params.wav
  }];
  // 上传比录音慢，超时给宽一点
  return request.postMultipart<VoiceCheckinResult>('/checkin/voice', fields, files,
    { timeout: 30000 });
}

/** 挑战码过期时间（毫秒时间戳），拿到就存下来给页面倒计时用 */
export function challengeExpireMillis(challenge: VoiceChallenge): number {
  return Date.now() + challenge.ttlSeconds * 1000;
}
