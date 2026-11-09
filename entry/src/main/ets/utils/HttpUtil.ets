import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 过滤用：hdc shell hilog | findstr HttpUtil */
const DOMAIN: number = 0x0000;
const TAG: string = 'HttpUtil';

/** AppStorage 里的 key，统一在这里定义，别到处写魔法字符串 */
export const TOKEN_KEY: string = 'TOKEN';
export const BASE_URL_KEY: string = 'BASE_URL';

/**
 * 接口基地址 —— 调试时【只需要改这一行】。
 *
 * 关键：真机和模拟器都必须填"电脑的局域网 IP"，绝对不能填 127.0.0.1。
 * 因为设备里的 127.0.0.1 指的是设备自己，不是你的电脑，只会报连不上。
 *
 * 调试三步：
 *   1. 电脑上执行 ipconfig，找 IPv4 地址（这台电脑现在是 192.168.31.50）
 *   2. 手机/模拟器和电脑连同一个 WiFi
 *   3. 后端必须真的在跑（浏览器打开 http://localhost:8080/user/login 能看到 405 之类的报错就说明活着）
 *
 * 如果换了网络、IP 变了（DHCP），就把下面这个地址改成 ipconfig 里新查到的那个。
 * 部分模拟器是 NAT 网络，局域网 IP 连不上时可以再试 http://10.0.2.2:8080
 */
export const DEFAULT_BASE_URL: string = 'http://192.168.31.50:8080';

/** 401（未登录 / token 失效）统一用这句提示，页面靠它判断要不要跳回登录页 */
export const ERR_UNAUTHORIZED: string = '登录已失效，请重新登录';

/**
 * 后端统一返回结构：code === 1 成功，code === 0 失败，失败原因看 msg。
 *
 * HTTP 状态码按《前后端联调文档》第 2.2 节：
 *   200 成功 / 400 参数错误 / 401 未登录或登录失败 / 403 非管理员 /
 *   404 不存在 / 405 方法不支持 / 415 Content-Type 不对 / 500 服务端异常
 * 除 200 外 body 里都还有 code=0 和可展示的 msg，所以提示语优先用 msg。
 */
interface ApiResponse<T> {
  code: number;
  msg: string;
  data: T;
}

export type HttpHeaders = Record<string, string>; // 类型定义不能放类里，单独放外面

// 2. 提取请求配置接口（避免裸对象与展开运算符报错）
export interface RequestConfig {
  header?: Record<string, string>;
  timeout?: number;
}

/** multipart 里的普通文本字段，例如 phraseTag=DIGIT_3 */
export interface MultipartField {
  fieldName: string;
  value: string;
}

/** multipart 里的二进制文件字段，例如 audio=xxx.wav */
export interface MultipartFile {
  fieldName: string;
  fileName: string;
  contentType: string;
  data: ArrayBuffer;
}

/** 401 错误的 name 标记，供 isUnauthorized() 判断（不能靠文案判断，文案来自后端） */
const UNAUTHORIZED_ERROR_NAME: string = 'UnauthorizedError';

/** 403 错误的 name 标记，供 isForbidden() 判断（例如"请先完成声纹注册"） */
const FORBIDDEN_ERROR_NAME: string = 'ForbiddenError';

/**
 * 带 HTTP 状态码的错误。
 *
 * 打卡接口要靠状态码区分后续动作（文档 5.4）：
 *   410 挑战码失效 + 429 次数超限 → 重新申请挑战码
 *   422 声纹/切段失败 → 重新录音（同一 nonce 最多 3 次）
 *   400 位置失败 → 用同一个 nonce 直接重提
 * 所以光有 msg 不够，必须把 status 带出去。
 */
export class HttpError extends Error {
  /** HTTP 状态码；business 错误（code=0 但 HTTP 200）记 200 */
  readonly status: number;

  constructor(status: number, message: string, name: string) {
    super(message);
    this.status = status;
    this.name = name;
  }
}

/** 取错误的 HTTP 状态码；网络层错误（连不上/超时）返回 0 */
export function errorStatus(error: Object): number {
  if (error instanceof HttpError) {
    return error.status;
  }
  return 0;
}

/**
 * 判断一个错误是不是"未登录 / token 失效"，页面用它决定是否跳登录页。
 *
 * 注意：不能写成 `error.message === ERR_UNAUTHORIZED` —— 现在 401 的提示语优先用后端的
 * （比如登录时的"用户名或密码错误"），文案是变的，所以用 name 打标记。
 */
export function isUnauthorized(error: Object): boolean {
  return error instanceof Error && error.name === UNAUTHORIZED_ERROR_NAME;
}

/**
 * 判断一个错误是不是 403（没有权限）。
 *
 * 两种 403 要区别对待：
 *   - 普通用户调管理员接口 → msg="没有访问权限"，只提示
 *   - 没录满声纹调 /attendance/task/mine → msg="请先完成声纹注册"，引导去录声纹
 * 都不是"登录失效"，绝对不能清 token 跳登录页。
 */
export function isForbidden(error: Object): boolean {
  return error instanceof Error && error.name === FORBIDDEN_ERROR_NAME;
}

// 3. 使用泛型 <T> 替代 any
async function getRequest<T>(url: string, method: http.RequestMethod, body?: object,
  config?: RequestConfig): Promise<T> {
  const httpRequest = http.createHttp();
  const timeout: number = config?.timeout ?? 10000;
  hilog.info(DOMAIN, TAG, '请求: %{public}s', `${method} ${url}`);
  try {
    const headers: HttpHeaders = { 'Content-Type': 'application/json' };

    // 有 token 才带。没登录时千万别把 undefined 塞进 header，
    // 那会变成字符串 "undefined" 发给后端，被当成无效 token。
    const token: string | undefined = AppStorage.get<string>(TOKEN_KEY);
    if (token) {
      headers['Authorization'] = `Bearer ${token}`;
    }

    if (config && config.header) {
      for (const key of Object.keys(config.header)) {
        headers[key] = config.header[key];
      }
    }

    const options: http.HttpRequestOptions = {
      method: method,
      header: headers,
      connectTimeout: timeout,
      readTimeout: timeout
    };

    // 后端用 @RequestBody 收 JSON，传对象有的版本会变成 [object Object]，所以手动序列化
    if (body !== undefined) {
      options.extraData = JSON.stringify(body);
    }

    const response = await httpRequest.request(url, options);
    hilog.info(DOMAIN, TAG, '响应: %{public}d %{public}s', response.responseCode, url);
    return handleResponse<T>(response, url);
  } catch (error) {
    throw wrapError(error, url);
  } finally {
    httpRequest.destroy();
  }
}

/**
 * 统一的响应处理：401 / 403 / 其它非 200 / code=0 都在这里转成 Error 抛出去。
 *
 * JSON 请求和 multipart（声纹注册）请求共用，避免两边判错逻辑不一致。
 */
function handleResponse<T>(response: http.HttpResponse, url: string): T {
  // ---- 401：未登录 / token 缺失 / token 失效 / 账号密码错误 ----
  // 后端 401 也会带具体原因（例如登录时的"用户名或密码错误"），
  // 所以提示语必须优先用后端 msg，不能写死成"登录已失效"。
  if (response.responseCode === 401) {
    const msg: string = safeMsg(response.result, ERR_UNAUTHORIZED);
    hilog.warn(DOMAIN, TAG, '未授权(401): %{public}s', `${url} 后端说: ${msg}`);
    AppStorage.delete(TOKEN_KEY);
    const authError = new HttpError(401, msg, UNAUTHORIZED_ERROR_NAME);
    throw authError; // 页面用 isUnauthorized() 判断
  }

  // ---- 403：登录了但没权限（非管理员 / 没录声纹），token 是好的，不能清 ----
  if (response.responseCode === 403) {
    const msg: string = safeMsg(response.result, '没有操作权限');
    hilog.warn(DOMAIN, TAG, '无权限(403): %{public}s', `${url} 后端说: ${msg}`);
    const forbiddenError = new HttpError(403, msg, FORBIDDEN_ERROR_NAME);
    throw forbiddenError; // 页面用 isForbidden() 判断
  }

  // ---- 其它非 200（400 参数错误 / 404 / 405 / 409 / 410 / 422 / 429 / 500 等）----
  // 后端每个错误都有自己的状态码，但 body 里一定有给用户看的 msg，优先用它
  if (response.responseCode !== 200) {
    const msg: string = safeMsg(response.result, `请求失败（HTTP ${response.responseCode}）`);
    throw new HttpError(response.responseCode, msg, 'HttpError');
  }

  if (!response.result) {
    return null as T;
  }

  const resObj = JSON.parse(response.result as string) as ApiResponse<T>;

  // ---- 业务结果：1 成功，0 失败 ----
  if (resObj.code === 1) {
    return resObj.data; // 返回真正的业务数据
  }
  throw new HttpError(200, resObj.msg, 'BizError');
}

/**
 * 统一的错误包装：把底层网络错误和业务错误都转成带可读 message 的 Error。
 *
 * 注意 name 必须带过去 —— 重新 new Error 会把 401/403 的标记冲掉，
 * 页面就再也判断不出该跳登录页还是该提示无权限了。
 */
function wrapError(error: Object, url: string): Error {
  // 已经是我们自己的带状态码错误，原样抛，别把 status 冲掉
  if (error instanceof HttpError) {
    return error;
  }
  let errorMsg: string = '未知错误';
  let errorName: string = '';
  if (error instanceof Error) {
    // 捕获我们自己 throw 的业务报错（比如"用户名或密码错误"）
    errorMsg = error.message;
    errorName = error.name;
  } else {
    // 捕获底层网络报错：连不上、超时、没开 WiFi……把 code 也带上，方便对照排查
    const err = error as BusinessError;
    const code: number | undefined = err.code;
    errorMsg = `${err.message || '网络连接异常'}（错误码 ${code}，地址 ${url}）`;
  }
  hilog.error(DOMAIN, TAG, '请求失败: %{public}s', errorMsg);
  const wrapped = new Error(errorMsg);
  wrapped.name = errorName;
  return wrapped;
}

/**
 * multipart/form-data 上传（声纹注册用）。
 *
 * 后端注册接口要的是 multipart，不是 JSON；鸿蒙这边不用自己拼 body，
 * 把 MultiFormData 数组塞进 extraData，底层会自动生成 boundary 并拼好请求体。
 * Content-Type 只写 multipart/form-data，boundary 由底层补，手写会 415。
 */
async function postMultipartRequest<T>(url: string, fields: MultipartField[],
  files: MultipartFile[], config?: RequestConfig): Promise<T> {
  const httpRequest = http.createHttp();
  // 上传比普通请求慢，默认给 30 秒
  const timeout: number = config?.timeout ?? 30000;
  hilog.info(DOMAIN, TAG, '上传: %{public}s', url);
  try {
    const headers: HttpHeaders = { 'Content-Type': 'multipart/form-data' };
    const token: string | undefined = AppStorage.get<string>(TOKEN_KEY);
    if (token) {
      headers['Authorization'] = `Bearer ${token}`;
    }

    const parts: http.MultiFormData[] = [];
    for (let i = 0; i < fields.length; i++) {
      parts.push({
        name: fields[i].fieldName,
        contentType: 'text/plain',
        data: fields[i].value
      });
    }
    for (let i = 0; i < files.length; i++) {
      // 二进制数据必须给 remoteFileName，否则后端收不到 filename、Spring 会当成没传文件
      parts.push({
        name: files[i].fieldName,
        contentType: files[i].contentType,
        remoteFileName: files[i].fileName,
        data: files[i].data
      });
    }

    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      // 表单数据走 multiFormDataList（SDK 明确要求：Content-Type 为 multipart/form-data 时用这个字段）
      multiFormDataList: parts,
      connectTimeout: timeout,
      readTimeout: timeout
    };

    const response = await httpRequest.request(url, options);
    hilog.info(DOMAIN, TAG, '上传响应: %{public}d %{public}s', response.responseCode, url);
    return handleResponse<T>(response, url);
  } catch (error) {
    throw wrapError(error, url);
  } finally {
    httpRequest.destroy();
  }
}

/**
 * 从响应体里安全地取出后端 msg；取不到就用 fallback。
 *
 * 统一响应的 body 一定是 { code, msg, data }，所以任何状态码（400/401/404/405/500）
 * 下都能拿到给用户看的提示，不用自己拼"HTTP Error: xxx"。
 */
function safeMsg(result: string | Object | ArrayBuffer, fallback: string): string {
  if (!result) {
    return fallback;
  }
  try {
    const obj = JSON.parse(result as string) as ApiResponse<Object>;
    return obj.msg ? obj.msg : fallback;
  } catch (err) {
    return fallback;
  }
}

// 1. 定义接口（约束形状）
interface IHttpClient {
  get<T>(url: string, data?: object, config?: RequestConfig): Promise<T>;
  post<T>(url: string, data?: object, config?: RequestConfig): Promise<T>;
  put<T>(url: string, data?: object, config?: RequestConfig): Promise<T>;
  delete<T>(url: string, data?: object, config?: RequestConfig): Promise<T>;
  /** multipart/form-data 上传（声纹注册） */
  postMultipart<T>(url: string, fields: MultipartField[], files: MultipartFile[],
    config?: RequestConfig): Promise<T>;
}

/** 取基地址，没配置就用默认值，并去掉结尾的 '/' 防止拼出双斜杠 */
const baseurl = (): string => {
  const url: string | undefined = AppStorage.get<string>(BASE_URL_KEY);
  const base: string = url ? url : DEFAULT_BASE_URL;
  return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
};

// 2. 使用 Class 来实现这个接口（彻底避开对象字面量的限制）
class HttpClientImpl implements IHttpClient {
  get<T>(url: string, data?: object, config?: RequestConfig): Promise<T> {
    return getRequest<T>(baseurl() + url, http.RequestMethod.GET, data, config);
  }

  post<T>(url: string, data?: object, config?: RequestConfig): Promise<T> {
    return getRequest<T>(baseurl() + url, http.RequestMethod.POST, data, config);
  }

  put<T>(url: string, data?: object, config?: RequestConfig): Promise<T> {
    return getRequest<T>(baseurl() + url, http.RequestMethod.PUT, data, config);
  }

  delete<T>(url: string, data?: object, config?: RequestConfig): Promise<T> {
    return getRequest<T>(baseurl() + url, http.RequestMethod.DELETE, data, config);
  }

  postMultipart<T>(url: string, fields: MultipartField[], files: MultipartFile[],
    config?: RequestConfig): Promise<T> {
    return postMultipartRequest<T>(baseurl() + url, fields, files, config);
  }
}

// 3. 导出这个类的实例 -- 必须创建class因为里面是有泛型的
export const request: IHttpClient = new HttpClientImpl();
