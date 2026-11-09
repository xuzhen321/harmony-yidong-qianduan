import { BusinessError } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { userAuth } from '@kit.UserAuthenticationKit';

/**
 * 系统级人脸验证封装（@kit.UserAuthenticationKit）。
 *
 * 为什么用系统这一套，而不是自己开相机拍脸再比对：
 *   - 系统验证的是**设备里已经录入的那张脸**（锁屏人脸），有活体检测，照片/视频骗不过；
 *   - 本 SDK 里没有 1:1 人脸比对的 kit（faceDetector / faceComparator 都不存在），
 *     自己做就得联网调云端或塞模型，既不算纯前端，安全性还更差；
 *   - 弹窗由系统渲染，账号密码不会经过相机，也没有隐私合规问题。
 *
 * 本文件只负责"问系统要一个 是/否"，不碰密码。
 */

/** ATL3 = 3D 人脸级别（Mate 系列支持）；ATL2 = 2D 人脸 + 标准活体 */
const FALLBACK_TRUST_LEVELS: userAuth.AuthTrustLevel[] = [
  userAuth.AuthTrustLevel.ATL3,
  userAuth.AuthTrustLevel.ATL2
];

export interface FaceAuthOutcome {
  ok: boolean;
  /** userAuth.UserAuthResultCode 原始码，方便排查 */
  code: number;
  message: string;
}

/** 把结果码翻译成人话 */
export function faceResultText(code: number): string {
  switch (code) {
    case userAuth.UserAuthResultCode.SUCCESS:
      return '验证成功';
    case userAuth.UserAuthResultCode.FAIL:
      return '人脸不匹配，请重试或手动输入密码';
    case userAuth.UserAuthResultCode.GENERAL_ERROR:
      return '人脸验证服务异常，请手动输入密码';
    case userAuth.UserAuthResultCode.CANCELED:
      return '已取消人脸验证';
    case userAuth.UserAuthResultCode.CANCELED_FROM_WIDGET:
      return '已取消人脸验证';
    case userAuth.UserAuthResultCode.TIMEOUT:
      return '人脸验证超时，请重试';
    case userAuth.UserAuthResultCode.TYPE_NOT_SUPPORT:
      return '本机不支持人脸验证，请手动输入密码';
    case userAuth.UserAuthResultCode.TRUST_LEVEL_NOT_SUPPORT:
      return '本机人脸安全等级不够，请手动输入密码';
    case userAuth.UserAuthResultCode.BUSY:
      return '验证过于频繁，请稍后再试';
    case userAuth.UserAuthResultCode.LOCKED:
      return '人脸验证已被锁定，请用锁屏密码解锁后再试';
    case userAuth.UserAuthResultCode.NOT_ENROLLED:
      return '本机还没录入人脸，请先在系统设置里录入';
    case userAuth.UserAuthResultCode.INVALID_PARAMETERS:
      return '人脸验证参数错误';
    default:
      return `人脸验证失败（${code}）`;
  }
}

/**
 * 本机能不能人脸验证。
 * getAvailableStatus 不支持时是**抛异常**（不是返回错误码），所以要 try 住。
 */
export function isFaceAvailable(): boolean {
  for (const level of FALLBACK_TRUST_LEVELS) {
    try {
      userAuth.getAvailableStatus(userAuth.UserAuthType.FACE, level);
      return true;
    } catch (err) {
      const code: number = (err as BusinessError).code;
      // 12500006 = 可信等级不支持 → 继续试下一档；12500005 = 本机根本没有人脸 → 直接 false
      if (code === userAuth.UserAuthResultCode.TYPE_NOT_SUPPORT) {
        return false;
      }
    }
  }
  return false;
}

/** 单次验证：指定可信等级 + 标题，等系统回调 */
function runAuthOnce(trustLevel: userAuth.AuthTrustLevel, title: string): Promise<FaceAuthOutcome> {
  // challenge 要随机，防重放；文档建议用 cryptoFramework 生成
  let challenge: Uint8Array = new Uint8Array([0]);
  try {
    const random: cryptoFramework.Random = cryptoFramework.createRandom();
    const blob: cryptoFramework.DataBlob = random.generateRandomSync(32);
    challenge = blob.data;
  } catch (err) {
    console.warn(`生成 face challenge 失败，用默认值: ${(err as BusinessError).message}`);
  }

  const authParam: userAuth.AuthParam = {
    challenge: challenge,
    authType: [userAuth.UserAuthType.FACE],
    authTrustLevel: trustLevel
  };
  const widgetParam: userAuth.WidgetParam = {
    title: title
  };

  return new Promise<FaceAuthOutcome>((resolve) => {
    let instance: userAuth.UserAuthInstance;
    try {
      instance = userAuth.getUserAuthInstance(authParam, widgetParam);
    } catch (err) {
      const code: number = (err as BusinessError).code;
      resolve({ ok: false, code: code, message: faceResultText(code) });
      return;
    }

    // on('result') 要的是 IAuthCallback 对象（不是裸函数），必须实现 onResult
    const callback: userAuth.IAuthCallback = {
      onResult: (result: userAuth.UserAuthResult): void => {
        resolve({
          ok: result.result === userAuth.UserAuthResultCode.SUCCESS,
          code: result.result,
          message: faceResultText(result.result)
        });
      }
    };
    instance.on('result', callback);

    try {
      instance.start();
    } catch (err) {
      const code: number = (err as BusinessError).code;
      resolve({ ok: false, code: code, message: faceResultText(code) });
    }
  });
}

/**
 * 发起一次人脸验证：先试 ATL3（3D 人脸），本机不支持该等级再退 ATL2。
 * 注意：用户取消也会走到这里并返回 ok=false，调用方不要把取消当异常。
 */
export async function verifyFace(title: string): Promise<FaceAuthOutcome> {
  let last: FaceAuthOutcome = { ok: false, code: -1, message: '本机不支持人脸验证' };
  for (const level of FALLBACK_TRUST_LEVELS) {
    const outcome: FaceAuthOutcome = await runAuthOnce(level, title);
    if (outcome.ok) {
      return outcome;
    }
    last = outcome;
    // 只有"可信等级不够/不支持"才值得换一档重试；取消、不匹配、超时直接返回，别烦用户
    const retryable: boolean = outcome.code === userAuth.UserAuthResultCode.TRUST_LEVEL_NOT_SUPPORT ||
      outcome.code === userAuth.UserAuthResultCode.TYPE_NOT_SUPPORT;
    if (!retryable) {
      return outcome;
    }
  }
  return last;
}
