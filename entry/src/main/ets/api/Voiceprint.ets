import { request, MultipartField, MultipartFile } from '../utils/HttpUtil';

/**
 * 声纹模块接口（`前后端联调文档-声纹模块.md` v1.0，2026-10-29）
 *
 * 本期只有三个能联调的接口：
 *   GET  /voiceprint/status          查自己的注册状态
 *   POST /voiceprint/enroll          注册一个数字模板（multipart）
 *   POST /voiceprint/reset/{userId}  管理员重置某人的声纹
 * 声纹打卡（/checkin/**）后端还没实现，前端不要接。
 *
 * 两个必须记住的点：
 *   1. 身份只从 token 取，接口不接受客户端传 userId
 *   2. 注册接口是 multipart/form-data，不是 JSON
 */

/** 声纹状态取值，和文档 1.3 节的表一一对应 */
export const VP_NOT_ENROLLED: string = 'NOT_ENROLLED'; // 还没有声纹档案 → 从 0 开始录
export const VP_ENROLLING: string = 'ENROLLING'; // 10 个数字没齐 → 继续录缺的
export const VP_ACTIVE: string = 'ACTIVE'; // 10 个数字齐全 → 可以打卡
export const VP_REVOKED: string = 'REVOKED'; // 被管理员重置 → 重新录

/** 本期只支持 10 个数字，整句模板 FIXED 传了返回 400 */
export const DIGIT_TAGS: string[] = [
  'DIGIT_0', 'DIGIT_1', 'DIGIT_2', 'DIGIT_3', 'DIGIT_4',
  'DIGIT_5', 'DIGIT_6', 'DIGIT_7', 'DIGIT_8', 'DIGIT_9'
];

export interface VoiceprintStatus {
  /** NOT_ENROLLED / ENROLLING / ACTIVE / REVOKED */
  status: string;
  /** 是否录了整句模板；本期恒为 false */
  hasFixedPhrase: boolean;
  /** 已完成的数字种类数 0~10 */
  digitCount: number;
  /** 还缺哪些数字，如 ['7'] —— 后端给的就是数字字符，不是 DIGIT_7 */
  missingDigits: string[];
  /** digitCount === 10 */
  readyForCheckin: boolean;
  /** 10 个数字全部录完的时间；没录完是 null */
  enrolledAt: string | null;
}

export interface EnrollResult {
  /** 模板 ID */
  profileId: number;
  /** DIGIT_0 ~ DIGIT_9 */
  phraseTag: string;
  /** MFCC 帧数 */
  frames: number;
  /** 录音时长（毫秒） */
  durationMs: number;
  /** 0~100 注册质量分，低于 60 后端会直接拒 */
  quality: number;
}

/** 查自己的声纹注册状态（没档案也返回 200 + NOT_ENROLLED） */
export function getVoiceprintStatus(): Promise<VoiceprintStatus> {
  return request.get<VoiceprintStatus>('/voiceprint/status', undefined, { timeout: 15000 });
}

/**
 * 注册一个数字模板。
 *
 * @param phraseTag DIGIT_0 ~ DIGIT_9
 * @param wav       16kHz / 16bit / 单声道 WAV 的完整字节（含 44 字节头）
 */
export function enrollDigit(phraseTag: string, wav: ArrayBuffer): Promise<EnrollResult> {
  const fields: MultipartField[] = [
    { fieldName: 'phraseTag', value: phraseTag }
  ];
  const files: MultipartFile[] = [
    { fieldName: 'audio', fileName: `${phraseTag}.wav`, contentType: 'audio/wav', data: wav }
  ];
  return request.postMultipart<EnrollResult>('/voiceprint/enroll', fields, files, { timeout: 30000 });
}

/**
 * 管理员重置某人的声纹。
 *
 * 重置后账号行保留、token 也不失效，用户重新录满 10 个数字即可恢复；
 * 但重置前录过的音频不能再注册（数据库留着模板哈希）。
 */
export function resetVoiceprint(userId: number): Promise<void> {
  return request.post<void>(`/voiceprint/reset/${userId}`, undefined, { timeout: 15000 });
}

/** 状态 → 中文文案，页面展示用 */
export function statusText(status: string): string {
  if (status === VP_ACTIVE) {
    return '已完成，可以打卡';
  }
  if (status === VP_ENROLLING) {
    return '录入中，还没录满 10 个数字';
  }
  if (status === VP_REVOKED) {
    return '已被管理员重置，需要重新录制';
  }
  return '还没有录制声纹';
}
