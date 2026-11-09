import { UIContext } from '@kit.ArkUI';
import { TOKEN_KEY } from './HttpUtil';

/**
 * 登录态统一管理。
 *
 * 为什么单独抽一个文件：token、用户信息、角色这三个东西
 * 登录页要写、我的页面要读、人员管理页要判断权限，
 * 散在各页面里到处写 AppStorage.setOrCreate('NICK_NAME', ...) 迟早写错一个 key。
 */

export const USER_ID_KEY: string = 'USER_ID';
export const USER_NAME_KEY: string = 'USER_NAME';
export const NICK_NAME_KEY: string = 'NICK_NAME';
export const ROLE_KEY: string = 'ROLE';
/** 声纹是否还没录齐：true 表示 /attendance/task/mine 会被 403 拦住 */
export const NEED_VOICEPRINT_KEY: string = 'NEED_VOICEPRINT';

export const ROLE_ADMIN: string = 'ADMIN';
export const ROLE_USER: string = 'USER';

/** 登录态里保存的用户信息 */
export interface SessionUser {
  userId: number;
  userName: string;
  nickName: string;
  role: string;
  /** 后端返回的 needVoiceprintEnroll；不传就沿用本地已有值 */
  needVoiceprintEnroll?: boolean;
}

/** 登录成功后保存整份登录态（token + 用户信息） */
export function saveSession(token: string, user: SessionUser): void {
  AppStorage.setOrCreate<string>(TOKEN_KEY, token);
  saveProfile(user);
}

/**
 * 只刷新用户信息，不动 token。
 * 改昵称、/user/info 刷新、自动登录校验都走这里。
 */
export function saveProfile(user: SessionUser): void {
  AppStorage.setOrCreate<number>(USER_ID_KEY, user.userId);
  AppStorage.setOrCreate<string>(USER_NAME_KEY, user.userName);
  AppStorage.setOrCreate<string>(NICK_NAME_KEY, user.nickName);
  AppStorage.setOrCreate<string>(ROLE_KEY, user.role);
  if (user.needVoiceprintEnroll !== undefined) {
    AppStorage.setOrCreate<boolean>(NEED_VOICEPRINT_KEY, user.needVoiceprintEnroll);
  }
}

export function getToken(): string {
  const token: string | undefined = AppStorage.get<string>(TOKEN_KEY);
  return token === undefined ? '' : token;
}

export function getUserId(): number {
  const id: number | undefined = AppStorage.get<number>(USER_ID_KEY);
  return id === undefined ? 0 : id;
}

export function getUserName(): string {
  const name: string | undefined = AppStorage.get<string>(USER_NAME_KEY);
  return name === undefined ? '' : name;
}

export function getNickName(): string {
  const nickName: string | undefined = AppStorage.get<string>(NICK_NAME_KEY);
  return nickName === undefined ? '' : nickName;
}

export function getRole(): string {
  const role: string | undefined = AppStorage.get<string>(ROLE_KEY);
  return role === undefined ? '' : role;
}

/**
 * 是否管理员。
 * 注意：这只用来决定"要不要显示入口"，真正的权限校验在后端，
 * 普通用户就算绕过界面直接调接口，后端也会返回 403。
 */
export function isAdmin(): boolean {
  return getRole() === ROLE_ADMIN;
}

/** 角色中文名，界面展示用 */
export function roleText(role: string): string {
  return role === ROLE_ADMIN ? '管理员' : '普通用户';
}

/**
 * 声纹是否还没录满 10 个数字。
 *
 * 登录和 /user/info 都会返回 needVoiceprintEnroll，这里只是给页面一个同步读的入口。
 * 本地没有这个标记时按 false 处理（不能默认 true，否则从没登过录的人也会看到"未注册"）。
 */
export function needVoiceprintEnroll(): boolean {
  const value: boolean | undefined = AppStorage.get<boolean>(NEED_VOICEPRINT_KEY);
  return value === undefined ? false : value;
}

/** 退出登录 / token 失效时统一清干净，别留半截登录态 */
export function clearSession(): void {
  AppStorage.delete(TOKEN_KEY);
  AppStorage.delete(USER_ID_KEY);
  AppStorage.delete(USER_NAME_KEY);
  AppStorage.delete(NICK_NAME_KEY);
  AppStorage.delete(ROLE_KEY);
  AppStorage.delete(NEED_VOICEPRINT_KEY);
}

/**
 * 清登录态 + 回登录页。
 *
 * 用 replaceUrl 而不是 pushUrl：把当前页从路由栈里替换掉，
 * 否则用户在新页面按返回键又能回到需要登录的页面。
 *
 * replaceUrl 会抛 BusinessError（例如页面不存在 100002），ArkTS 要求显式处理，所以包了 try/catch。
 */
export async function gotoLogin(ui: UIContext): Promise<void> {
  clearSession();
  try {
    await ui.getRouter().replaceUrl({ url: 'pages/Login' });
  } catch (err) {
    console.error(`跳转登录页失败: ${JSON.stringify(err)}`);
  }
}
