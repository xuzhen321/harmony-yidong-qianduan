import { request } from '../utils/HttpUtil';
import { PageResult } from './UserLogin';

/**
 * 考勤任务接口（对应《前后端联调文档-考勤任务模块.md》）。
 *
 *   POST /attendance/task            管理员创建任务
 *   GET  /attendance/task/page       管理员分页查询任务
 *   GET  /attendance/task/{taskId}   管理员查看任务详情（含名单完成情况）
 *   GET  /attendance/task/mine       登录用户查看自己的任务
 *
 * 后端约定（文档第 1 节）：
 *   - 请求里的时间要 ISO-8601 带时区，例如 2026-10-28T08:00:00+08:00
 *   - 响应里的时间是服务器本地时间，例如 2026-10-28T08:00:00 / 2026-10-28T08:00:00.277
 *   - 任务只有 UPCOMING / OPEN / CLOSED 三种状态，过了 endAt 自动变 CLOSED，前端不用自己算
 *   - 任务创建后不能改、不能取消、不能删除
 */

/* ==================== 数据结构 ==================== */

/** 创建任务请求 POST /attendance/task */
export interface CreateAttendanceTaskRequest {
  /** 不传默认按日期和类型生成，例如 "2026-10-28 上班打卡" */
  title?: string;
  /** 'IN' 上班 / 'OUT' 下班 */
  checkType: string;
  /** 带时区，例如 2026-10-28T08:00:00+08:00 */
  startAt: string;
  /** 必须晚于 startAt */
  endAt: string;
  /** 指定人员，去重后 1~500 个 */
  userIds: number[];
  /**
   * 打卡点纬度（WGS84）。和 longitude 必须同时给或同时不给，
   * 都不给就是"不限位置"，老任务完全兼容。
   */
  latitude?: number;
  /** 打卡点经度（WGS84） */
  longitude?: number;
  /** 允许打卡半径，默认 200，范围 50~1000 */
  radiusM?: number;
  /** 地点名称，最长 128，仅用来展示 */
  address?: string;
}

export interface CreateAttendanceTaskResult {
  taskId: number;
  participantCount: number;
}

/** 管理员任务列表里的一行 */
export interface AttendanceTaskListItem {
  taskId: number;
  title: string;
  checkType: string;
  startAt: string;
  endAt: string;
  /** UPCOMING 未开始 / OPEN 进行中 / CLOSED 已结束 */
  state: string;
  participantCount: number;
  doneCount: number;
  createdBy: number;
  createdAt: string;
  /** 打卡点纬度；不限位置时为 null（字段不会省略） */
  latitude: number | null;
  /** 打卡点经度；不限位置时为 null */
  longitude: number | null;
  /** 允许半径（米）；不限位置时为 null */
  radiusM: number | null;
  /** 地点名称；不限位置时为 null */
  address: string | null;
}

/** 任务名单里的一个人 */
export interface AttendanceTaskParticipant {
  userId: number;
  userName: string;
  nickName: string;
  /** PENDING 待打卡 / DONE 已完成 */
  status: string;
  checkedAt: string | null;
  recordId: number | null;
  /** VOICE 声纹打卡 / MANUAL 管理员补卡；未打卡为 null */
  source: string | null;
  /** 补卡管理员 ID；声纹打卡或未打卡为 null */
  operatorId: number | null;
  /** 补卡备注；声纹打卡或未打卡为 null */
  remark: string | null;
}

/** 任务详情 GET /attendance/task/{taskId} */
export interface AttendanceTaskDetail {
  taskId: number;
  title: string;
  checkType: string;
  startAt: string;
  endAt: string;
  state: string;
  participants: AttendanceTaskParticipant[];
  /** 下面四个和列表一致：有坐标才有值，不限位置为 null */
  latitude: number | null;
  longitude: number | null;
  radiusM: number | null;
  address: string | null;
}

/** 我自己的任务 GET /attendance/task/mine */
export interface MyAttendanceTask {
  taskId: number;
  title: string;
  checkType: string;
  startAt: string;
  endAt: string;
  state: string;
  done: boolean;
  checkedAt: string | null;
  /** 打卡点纬度；不限位置时为 null */
  latitude: number | null;
  /** 打卡点经度；不限位置时为 null */
  longitude: number | null;
  /** 允许半径（米）；不限位置时为 null */
  radiusM: number | null;
  /** 地点名称；不限位置时为 null */
  address: string | null;
}

export type AttendanceTaskPage = PageResult<AttendanceTaskListItem>;
export type MyAttendanceTaskPage = PageResult<MyAttendanceTask>;

/* ==================== 管理员补卡 ==================== */

/** 补卡请求 POST /attendance/record/manual */
export interface ManualRecordRequest {
  taskId: number;
  /** 必须在任务名单内 */
  userId: number;
  /** 实际打卡时间，带时区；不传默认当前时间；不能晚于当前时间 */
  checkAt?: string;
  /** 备注，最长 128 */
  remark?: string;
}

/** 补卡 / 修改补卡的返回结构 */
export interface ManualRecordResult {
  recordId: number;
  taskId: number;
  userId: number;
  checkType: string;
  /** 2026-10-29 */
  recordDate: string;
  /** 服务器本地时间，不带时区 */
  checkedAt: string;
  /** VOICE / MANUAL */
  source: string;
  /** 操作的管理员 ID */
  operatorId: number;
  /** 备注，可能为 null */
  remark: string | null;
}

/** 修改补卡请求 PUT /attendance/record/{recordId}/manual（两个字段都可选） */
export interface UpdateManualRecordRequest {
  checkAt?: string;
  /** 传空字符串表示清空备注 */
  remark?: string;
}

/** GET /attendance/task/page 的查询参数（都可选） */
export interface AttendanceTaskPageQuery {
  state?: string;
  checkType?: string;
  pageNum?: number;
  pageSize?: number;
}

/* ==================== 接口 ==================== */

/** 管理员创建考勤任务。成功后 data 是 { taskId, participantCount } */
export const createAttendanceTask =
  (params: CreateAttendanceTaskRequest): Promise<CreateAttendanceTaskResult> => {
    return request.post<CreateAttendanceTaskResult>('/attendance/task', params);
  };

/**
 * 管理员分页查询任务。
 * state / checkType 不传就是"全部"，不要传空字符串占位，直接不拼进 URL。
 */
export const pageAttendanceTasks = (query: AttendanceTaskPageQuery): Promise<AttendanceTaskPage> => {
  const params: string[] = [];
  if (query.state !== undefined && query.state.length > 0) {
    params.push(`state=${query.state}`);
  }
  if (query.checkType !== undefined && query.checkType.length > 0) {
    params.push(`checkType=${query.checkType}`);
  }
  params.push(`pageNum=${query.pageNum !== undefined ? query.pageNum : 1}`);
  params.push(`pageSize=${query.pageSize !== undefined ? query.pageSize : 10}`);
  return request.get<AttendanceTaskPage>(`/attendance/task/page?${params.join('&')}`);
};

/** 管理员查看任务详情（任务不存在时后端 404 "考勤任务不存在"） */
export const getAttendanceTaskDetail = (taskId: number): Promise<AttendanceTaskDetail> => {
  return request.get<AttendanceTaskDetail>(`/attendance/task/${taskId}`);
};

/**
 * 当前登录用户查看自己的任务（不需要传 userId，后端只认 token）。
 *
 * 没录满 10 个声纹数字时后端返回 HTTP 403 + msg="请先完成声纹注册"，
 * 页面用 isForbidden() 判断后展示提示，不要按"登录失效"处理。
 */
export const pageMyAttendanceTasks = (pageNum: number, pageSize: number): Promise<MyAttendanceTaskPage> => {
  return request.get<MyAttendanceTaskPage>(`/attendance/task/mine?pageNum=${pageNum}&pageSize=${pageSize}`);
};

/**
 * 管理员补卡（员工忘记打卡时代为标记已完成）。
 *
 * 规则（文档 6.1）：
 *   - 任务必须已经开始，已结束的任务也允许补卡
 *   - 员工必须在名单内且尚未打卡，否则 409 "该员工已完成打卡"
 *   - 补卡不要求员工录过声纹
 */
export const createManualRecord = (params: ManualRecordRequest): Promise<ManualRecordResult> => {
  return request.post<ManualRecordResult>('/attendance/record/manual', params);
};

/** 修改补卡时间 / 备注，只能改 source=MANUAL 的记录 */
export const updateManualRecord = (recordId: number,
  params: UpdateManualRecordRequest): Promise<ManualRecordResult> => {
  return request.put<ManualRecordResult>(`/attendance/record/${recordId}/manual`, params);
};

/** 撤销补卡（逻辑删除，名单恢复 PENDING） */
export const revokeManualRecord = (recordId: number): Promise<void> => {
  return request.post<void>(`/attendance/record/${recordId}/revoke`);
};

/* ==================== 状态文案 ==================== */

export const STATE_UPCOMING: string = 'UPCOMING';
export const STATE_OPEN: string = 'OPEN';
export const STATE_CLOSED: string = 'CLOSED';

export const CHECK_TYPE_IN: string = 'IN';
export const CHECK_TYPE_OUT: string = 'OUT';

/** 任务状态中文名 */
export function stateText(state: string): string {
  if (state === STATE_UPCOMING) {
    return '未开始';
  }
  if (state === STATE_OPEN) {
    return '进行中';
  }
  if (state === STATE_CLOSED) {
    return '已结束';
  }
  return state;
}

/** 打卡类型中文名（课程打卡：上课 / 下课） */
export function checkTypeText(checkType: string): string {
  return checkType === CHECK_TYPE_OUT ? '下课' : '上课';
}

/* ==================== 时间工具 ==================== */

export interface DateTimeParts {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
}

export function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/**
 * 把用户输入的 "2026-10-28 08:00"（也接受 T 分隔）解析成数字。
 * 格式不对、月份日期小时越界都返回 null，交给调用方提示。
 */
export function parseDateTimeText(text: string): DateTimeParts | null {
  const normalized: string = text.trim().replace('T', ' ');
  // 允许多打空格：先按空格切，再把空串丢掉，只留下"日期"和"时间"两段
  const blocks: string[] = [];
  const rawBlocks: string[] = normalized.split(' ');
  for (let i = 0; i < rawBlocks.length; i++) {
    if (rawBlocks[i].length > 0) {
      blocks.push(rawBlocks[i]);
    }
  }
  if (blocks.length !== 2) {
    return null;
  }
  const dateParts: string[] = blocks[0].split('-');
  const timeParts: string[] = blocks[1].split(':');
  if (dateParts.length !== 3 || timeParts.length < 2) {
    return null;
  }
  const year: number = Number(dateParts[0]);
  const month: number = Number(dateParts[1]);
  const day: number = Number(dateParts[2]);
  const hour: number = Number(timeParts[0]);
  const minute: number = Number(timeParts[1]);
  if (isNaN(year) || isNaN(month) || isNaN(day) || isNaN(hour) || isNaN(minute)) {
    return null;
  }
  if (year < 2000 || year > 2100 || month < 1 || month > 12 || day < 1 || day > 31) {
    return null;
  }
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
    return null;
  }
  // 防止 2 月 31 日这种"看起来合法"的日期
  const check: Date = new Date(year, month - 1, day);
  if (check.getFullYear() !== year || check.getMonth() !== month - 1 || check.getDate() !== day) {
    return null;
  }
  return { year: year, month: month, day: day, hour: hour, minute: minute };
}

/**
 * 拼成后端要的 ISO-8601 带时区字符串：2026-10-28T08:00:00+08:00。
 *
 * 时区偏移不是写死的 +08:00，而是取设备在这台时间下的真实偏移，
 * 以后设备换了时区也不会错。
 */
export function toIsoWithOffset(parts: DateTimeParts): string {
  const date: Date = new Date(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, 0);
  const offsetMinutes: number = -date.getTimezoneOffset();
  const sign: string = offsetMinutes >= 0 ? '+' : '-';
  const abs: number = Math.abs(offsetMinutes);
  const offsetHour: number = Math.floor(abs / 60);
  const offsetMinute: number = abs % 60;
  return `${parts.year}-${pad2(parts.month)}-${pad2(parts.day)}` +
    `T${pad2(parts.hour)}:${pad2(parts.minute)}:00` +
    `${sign}${pad2(offsetHour)}:${pad2(offsetMinute)}`;
}

/** 转成毫秒数，用来比较两个时间前后 */
export function partsToMillis(parts: DateTimeParts): number {
  return new Date(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, 0).getTime();
}

/** 设备当前时间，拼成输入框的默认值 "2026-10-28 08:00" */
export function nowText(hour: number, minute: number): string {
  const now: Date = new Date();
  return `${now.getFullYear()}-${pad2(now.getMonth() + 1)}-${pad2(now.getDate())} ` +
    `${pad2(hour)}:${pad2(minute)}`;
}

/**
 * 设备当前时间往后推 minutesAhead 分钟，拼成输入框默认值 "2026-11-10 12:47"。
 * 用来给「允许打卡时间」预填：开始 = 现在，结束 = 现在 + 30 分钟。
 */
export function nowTextAfter(minutesAhead: number): string {
  const target: Date = new Date(Date.now() + minutesAhead * 60 * 1000);
  return `${target.getFullYear()}-${pad2(target.getMonth() + 1)}-${pad2(target.getDate())} ` +
    `${pad2(target.getHours())}:${pad2(target.getMinutes())}`;
}

/**
 * 把响应里的时间显示成 "10-28 08:00"。
 * 后端返回 2026-10-28T08:00:00 或 2026-10-28T08:00:00.277，两种都要能吃。
 */
export function formatTaskTime(value: string | null): string {
  if (value === null || value.length === 0) {
    return '—';
  }
  const blocks: string[] = value.split('T');
  if (blocks.length !== 2) {
    return value;
  }
  const dateParts: string[] = blocks[0].split('-');
  const timePart: string = blocks[1].substring(0, 5);
  if (dateParts.length !== 3) {
    return `${dateParts.join('-')} ${timePart}`;
  }
  return `${dateParts[1]}-${dateParts[2]} ${timePart}`;
}
