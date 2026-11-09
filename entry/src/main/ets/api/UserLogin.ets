import { request } from '../utils/HttpUtil';

/**
 * 用户模块接口（登录 / 个人资料 / 管理员用户管理）。
 *
 * 全部按照《前后端联调文档-登录模块.md》实现，字段名严格 camelCase：
 * userName、nickName、oldPassword、newPassword、pageNum、pageSize。
 *
 * 注意 HttpUtil 已经帮我们拆好了 { code, msg, data }：
 *   - code === 1 → 直接返回 data 里的内容
 *   - code === 0 / 非 200 → 抛出 Error(msg)，页面直接展示 message 即可
 * 所以下面每个函数返回的就是后端 data，不再包一层。
 */

/* ==================== 数据结构 ==================== */

/** 登录请求 POST /user/login */
export interface LoginRequest {
  userName: string;
  password: string;
}

/** 登录成功返回 */
export interface LoginResult {
  token: string;
  userId: number;
  userName: string;
  nickName: string;
  /** 'ADMIN' 或 'USER' */
  role: string;
  /** true = 10 个声纹数字还没录齐（此时 /attendance/task/mine 会 403） */
  needVoiceprintEnroll?: boolean;
}

/** 当前用户信息 GET /user/info */
export interface UserInfo {
  token?: string;
  userId: number;
  userName: string;
  nickName: string;
  role: string;
  needVoiceprintEnroll?: boolean;
}

/** 管理员创建账号 POST /user */
export interface CreateUserRequest {
  /** 必填，最长 32，不能重复（已冻结的账号也算重复） */
  userName: string;
  /** 必填，6~32 个字符 */
  password: string;
  /** 可选，不传默认"新用户" */
  nickName?: string;
  /** 可选，'USER' / 'ADMIN'，不传默认 USER */
  role?: string;
}

/** 修改自己的密码 PUT /user/password */
export interface ChangePasswordRequest {
  oldPassword: string;
  newPassword: string;
}

/** 修改自己的昵称 PUT /user/nickname */
export interface UpdateNicknameRequest {
  nickName: string;
}

/** 管理员重置密码 PUT /user/password/{userId} */
export interface AdminResetPasswordRequest {
  newPassword: string;
}

/** 用户管理列表里的一行（不含密码） */
export interface UserListItem {
  id: number;
  userName: string;
  nickName: string;
  role: string;
  /** 0 正常，1 已冻结 */
  deleted: number;
}

/** 分页结果 */
export interface PageResult<T> {
  pageNum: number;
  pageSize: number;
  total: number;
  pages: number;
  records: T[];
}

export type UserPage = PageResult<UserListItem>;

/** GET /user/page 的查询参数（都可选） */
export interface UserPageQuery {
  userName?: string;
  deleted?: number;
  pageNum?: number;
  pageSize?: number;
}

/* ==================== 登录相关 ==================== */

/** 登录。用法：await login({ userName: 'admin', password: '123456' }) */
export const login = (params: LoginRequest): Promise<LoginResult> => {
  return request.post<LoginResult>('/user/login', params);
};

/** 获取当前登录用户（token 由 HttpUtil 自动放进请求头，不用手动传） */
export const getUserInfo = (): Promise<UserInfo> => {
  return request.get<UserInfo>('/user/info');
};

/** 退出登录：让服务端的 token 立刻失效 */
export const logout = (): Promise<void> => {
  return request.post<void>('/user/logout');
};

/* ==================== 个人资料 ==================== */

/** 修改自己的密码（成功后该用户所有 token 立即失效，要回登录页） */
export const changePassword = (params: ChangePasswordRequest): Promise<void> => {
  return request.put<void>('/user/password', params);
};

/** 修改自己的昵称（不会让 token 失效） */
export const updateNickname = (params: UpdateNicknameRequest): Promise<void> => {
  return request.put<void>('/user/nickname', params);
};

/* ==================== 管理员 ==================== */

/**
 * 管理员创建账号（文档 6.5）。
 *
 * 成功后 data 是 null，也不会自动登录；新用户首次登录会拿到
 * needVoiceprintEnroll=true，要先录满 10 个数字才能看自己的考勤任务。
 * 用户名重复时后端 409，msg 分别是"用户名已存在"或
 * "用户名已存在且已被冻结，请先恢复账号或换一个用户名"，直接展示即可。
 */
export const createUser = (params: CreateUserRequest): Promise<void> => {
  return request.post<void>('/user', params);
};

/**
 * 分页查询用户。
 * 只把有值的参数拼进 URL：deleted 不传表示"正常 + 已冻结"都返回。
 */
export const pageUsers = (query: UserPageQuery): Promise<UserPage> => {
  const params: string[] = [];
  if (query.userName !== undefined && query.userName.length > 0) {
    params.push(`userName=${encodeURIComponent(query.userName)}`);
  }
  if (query.deleted !== undefined) {
    params.push(`deleted=${query.deleted}`);
  }
  params.push(`pageNum=${query.pageNum !== undefined ? query.pageNum : 1}`);
  params.push(`pageSize=${query.pageSize !== undefined ? query.pageSize : 10}`);
  return request.get<UserPage>(`/user/page?${params.join('&')}`);
};

/** 冻结用户（逻辑删除，deleted 0 → 1） */
export const freezeUser = (userId: number): Promise<void> => {
  return request.delete<void>(`/user/${userId}`);
};

/** 恢复用户（deleted 1 → 0，对方需要重新登录） */
export const restoreUser = (userId: number): Promise<void> => {
  return request.put<void>(`/user/${userId}/restore`);
};

/** 管理员重置某个用户的密码（目标用户 ID 放在 URL 路径里，不在 body 里） */
export const adminResetPassword = (userId: number, params: AdminResetPasswordRequest): Promise<void> => {
  return request.put<void>(`/user/password/${userId}`, params);
};
