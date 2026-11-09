import { asset } from '@kit.AssetStoreKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';

/**
 * 「人脸登录」用的账号密码保险箱（@kit.AssetStoreKit）。
 *
 * 为什么用 Asset 而不是 Preferences/HUKS 手搓：
 *   - Asset（应用数据保护）就是系统给第三方应用存**小秘密**的保险箱，落盘由系统用设备密钥加密，
 *     密钥由系统托管，App 拿不到，root 后拷走文件也解不开；
 *   - Preferences 存的是一坨明文，HUKS 自己搓 AES-GCM 会话要写 100+ 行而且很容易写错；
 *   - Asset 还支持 ACCESSIBILITY（解锁后才能读），设备一重启、没解锁就取不到密码，天然安全一档。
 *
 * 支持**多账号**：一台设备上可以同时记住 admin / zhen 等几个账号（上限 5 个），
 * 登录页默认用上一次用过的那个，点「切换账号」可以挑别人刷脸进。
 *
 * 这里**额外做设备绑定**：把 deviceInfo.ODID（应用级设备标识）跟每条凭证一起存，
 * 读的时候比对——换手机/恢复备份到别的机器上，凭证直接作废，不会"复制一份就能刷脸登录"。
 */

const CRED_ALIAS: string = 'login_face_credential_v1';
/** 一台设备最多记几个账号，多了没意义还占保险箱 */
const MAX_ACCOUNTS: number = 5;

function utf8Bytes(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}

function bytesToUtf8(bytes: Uint8Array): string {
  return new util.TextDecoder().decodeToString(bytes);
}

function aliasQuery(): asset.AssetMap {
  const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
  query.set(asset.Tag.ALIAS, utf8Bytes(CRED_ALIAS));
  return query;
}

export interface SavedLogin {
  userId: number;
  userName: string;
  password: string;
  /** 存凭证时那台设备的 ODID，读的时候必须一致 */
  odid: string;
}

export interface SavedVault {
  /** 上一次用过的账号，登录页默认拿它当人脸按钮 */
  lastUserName: string;
  accounts: SavedLogin[];
}

/** 当前设备标识，拿不到就返回空串（空串不匹配任何已存凭证，等于禁用） */
function currentOdid(): string {
  try {
    return deviceInfo.ODID;
  } catch (err) {
    console.warn(`读取 ODID 失败: ${(err as BusinessError).message}`);
    return '';
  }
}

function emptyVault(): SavedVault {
  return { lastUserName: '', accounts: [] };
}

/** 真正读写那一份 JSON（只有内部用） */
async function readRaw(): Promise<SavedVault> {
  const query: asset.AssetMap = aliasQuery();
  query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);

  let rows: Array<asset.AssetMap>;
  try {
    rows = await asset.query(query);
  } catch (err) {
    const code: number = (err as BusinessError).code;
    if (code !== asset.ErrorCode.NOT_FOUND) {
      console.warn(`读取人脸登录凭证失败: ${(err as BusinessError).message}`);
    }
    return emptyVault();
  }
  if (rows.length === 0) {
    return emptyVault();
  }
  const secret: asset.Value | undefined = rows[0].get(asset.Tag.SECRET);
  if (secret === undefined || typeof secret !== 'object') {
    return emptyVault();
  }
  try {
    const parsed: SavedVault = JSON.parse(bytesToUtf8(secret as Uint8Array)) as SavedVault;
    if (parsed.accounts === undefined) {
      // 兼容上一版"单账号"存的格式（就是一条 SavedLogin 的 JSON），别让老凭证白丢
      const legacy: SavedLogin = JSON.parse(bytesToUtf8(secret as Uint8Array)) as SavedLogin;
      if (legacy.userName !== undefined && legacy.password !== undefined) {
        return { lastUserName: legacy.userName, accounts: [legacy] };
      }
      return emptyVault();
    }
    return parsed;
  } catch (err) {
    console.warn(`人脸登录凭证内容损坏，清掉重来: ${(err as BusinessError).message}`);
    await clearLogin();
    return emptyVault();
  }
}

async function writeVault(vault: SavedVault): Promise<void> {
  const odid: string = currentOdid();
  if (odid.length === 0) {
    throw new Error('本机取不到设备标识，无法开启人脸登录');
  }
  await clearLogin();

  const attrs: asset.AssetMap = new Map<asset.Tag, asset.Value>();
  attrs.set(asset.Tag.SECRET, utf8Bytes(JSON.stringify(vault)));
  attrs.set(asset.Tag.ALIAS, utf8Bytes(CRED_ALIAS));
  // 必须等设备解锁过一次才能读——重启后没解锁就取不到密码
  attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
  attrs.set(asset.Tag.DATA_LABEL_NORMAL_1, utf8Bytes('login'));
  try {
    await asset.add(attrs);
  } catch (err) {
    const code: number = (err as BusinessError).code;
    throw new Error(`保存人脸登录凭证失败（${code}）`);
  }
}

/** 只返回本机可用的账号（别的设备迁移过来的会被过滤掉） */
export async function loadVault(): Promise<SavedVault> {
  const raw: SavedVault = await readRaw();
  const odid: string = currentOdid();
  const mine: SavedLogin[] = raw.accounts.filter((item: SavedLogin) => item.odid === odid);
  const last: string = mine.some((item: SavedLogin) => item.userName === raw.lastUserName)
    ? raw.lastUserName
    : (mine.length > 0 ? mine[0].userName : '');
  return { lastUserName: last, accounts: mine };
}

/**
 * 兼容旧用法：只要"当前这台设备、上一次用过"的那个账号。
 * （内部是数组存储，将来想做多账号切换直接换成 loadVault 就行）
 */
export async function loadLogin(): Promise<SavedLogin | undefined> {
  const vault: SavedVault = await loadVault();
  return vault.accounts.find((item: SavedLogin) => item.userName === vault.lastUserName);
}

/** 存/更新一个账号，并把它设为"上次使用" */
export async function saveLogin(userName: string, password: string, userId: number): Promise<void> {
  const vault: SavedVault = await loadVault();
  const others: SavedLogin[] = vault.accounts.filter((item: SavedLogin) => item.userName !== userName);
  const entry: SavedLogin = {
    userId: userId,
    userName: userName,
    password: password,
    odid: currentOdid()
  };
  others.unshift(entry);
  vault.accounts = others.slice(0, MAX_ACCOUNTS);
  vault.lastUserName = userName;
  await writeVault(vault);
}

/** 只删一个账号；删完就清空整个凭证 */
export async function removeLogin(userName: string): Promise<void> {
  const vault: SavedVault = await loadVault();
  const rest: SavedLogin[] = vault.accounts.filter((item: SavedLogin) => item.userName !== userName);
  if (rest.length === 0) {
    await clearLogin();
    return;
  }
  vault.accounts = rest;
  if (vault.lastUserName === userName) {
    vault.lastUserName = rest[0].userName;
  }
  await writeVault(vault);
}

/** 清掉全部凭证；本来就没有也算成功（重装/首次使用） */
export async function clearLogin(): Promise<void> {
  try {
    await asset.remove(aliasQuery());
  } catch (err) {
    const code: number = (err as BusinessError).code;
    if (code !== asset.ErrorCode.NOT_FOUND) {
      console.warn(`清除人脸登录凭证失败: ${(err as BusinessError).message}`);
    }
  }
}
