import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { VoiceChallenge, VoiceCheckinResult, getVoiceChallenge, submitVoiceCheckin } from '../api/Checkin';
import { checkTypeText, formatTaskTime } from '../api/Attendance';
import {
  GeoPoint,
  ensureLocationPermission,
  formatDistance,
  getCurrentGeoPoint,
  haversine
} from '../utils/Location';
import { gotoLogin } from '../utils/AuthStore';
import { errorStatus, isUnauthorized } from '../utils/HttpUtil';
import { RecordedWav, recordWav } from '../utils/Recorder';

/**
 * 声纹 + 位置打卡页（`前后端联调文档-打卡模块.md` v1.0，第 5 / 7.1 节）
 *
 * 流程：
 *   进页面 → 有坐标的任务先取一次定位，显示"距离打卡点 xx 米"
 *   点"开始打卡" → GET /checkin/voice-challenge 拿 4 位数字（60 秒有效）
 *   点"开始录音" → 录 4.5 秒 WAV（后端要 3~6 秒）→ POST /checkin/voice
 *   成功 → 显示打卡时间/距离/声纹分数；失败 → 按 400/409/410/422/429 分别处理
 *
 * 重试规则（文档 5.4）：
 *   400 位置类 → 同一个 nonce 可以直接重提，60 秒内有效
 *   422 声纹/切段 → 重新录音，同一 nonce 最多 3 次
 *   410 / 429 → 重新申请挑战码
 *   401 → 清 token 回登录页
 */

/** 录多久：后端要求 3~6 秒，取 4.5 秒（4 个数字 + 每个约 0.2 秒间隔刚好够） */
const RECORD_MS: number = 4500;
/** 定位超时，文档要求 8000ms */
const LOCATE_TIMEOUT_MS: number = 8000;

/** 从"我的考勤"跳过来时带的参数 */
interface CheckinParams {
  taskId: number;
  title: string;
  checkType: string;
  startAt: string;
  endAt: string;
  /** 打卡点纬度；不限位置的任务不下发 */
  latitude?: number;
  longitude?: number;
  radiusM?: number;
  address?: string;
}

/** 页面阶段：idle 待开始 / locating 定位中 / challenge 等录音 / recording 录音中 / uploading 上传中 / done 成功 */
const PHASE_IDLE: string = 'idle';
const PHASE_LOCATING: string = 'locating';
const PHASE_CHALLENGE: string = 'challenge';
const PHASE_RECORDING: string = 'recording';
const PHASE_UPLOADING: string = 'uploading';
const PHASE_DONE: string = 'done';

@Entry
@ComponentV2
struct Checkin {
  /* ---- 任务信息（由上一页传进来） ---- */
  @Local taskId: number = 0;
  @Local title: string = '';
  @Local checkType: string = 'IN';
  @Local startAt: string = '';
  @Local endAt: string = '';
  @Local address: string = '';
  /** 任务有没有打卡点 */
  @Local hasLocation: boolean = false;
  @Local targetLatitude: number = 0;
  @Local targetLongitude: number = 0;
  @Local radiusM: number = 200;

  /* ---- 运行时状态 ---- */
  @Local phase: string = PHASE_IDLE;
  @Local geo: GeoPoint | undefined = undefined;
  /** 离打卡点的距离（米），-1 表示还没算 */
  @Local distanceM: number = -1;
  @Local challenge: VoiceChallenge | undefined = undefined;
  /** 挑战码剩余秒数 */
  @Local remainSec: number = 0;
  /** 同一个 nonce 已经失败几次（后端最多允许 3 次） */
  @Local failCount: number = 0;
  @Local tip: string = '';
  @Local result: VoiceCheckinResult | undefined = undefined;

  private countdownTimer: number = -1;

  aboutToAppear(): void {
    const params: CheckinParams = this.getUIContext().getRouter().getParams() as CheckinParams;
    if (params === undefined || params === null) {
      this.tip = '参数丢失，请返回重新进入';
      return;
    }
    this.taskId = params.taskId;
    this.title = params.title;
    this.checkType = params.checkType;
    this.startAt = params.startAt;
    this.endAt = params.endAt;
    this.address = params.address !== undefined && params.address !== null ? params.address : '';
    this.hasLocation = params.latitude !== undefined && params.latitude !== null &&
      params.longitude !== undefined && params.longitude !== null;
    if (this.hasLocation) {
      this.targetLatitude = params.latitude as number;
      this.targetLongitude = params.longitude as number;
      this.radiusM = params.radiusM !== undefined && params.radiusM !== null ? params.radiusM : 200;
      // 有坐标的任务，进页面就把距离算出来给用户看
      this.locateOnly();
    }
  }

  aboutToDisappear(): void {
    this.stopCountdown();
  }

  /* ==================== 定位 ==================== */

  /** 只定位、不算打卡（进页面先用，让用户知道差多远） */
  async locateOnly(): Promise<void> {
    this.phase = PHASE_LOCATING;
    this.tip = '';
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const granted: boolean = await ensureLocationPermission(context);
      if (!granted) {
        this.tip = '没拿到定位权限，请在系统设置里允许"位置信息"后再打卡';
        this.phase = PHASE_IDLE;
        return;
      }
      const point: GeoPoint = await getCurrentGeoPoint(LOCATE_TIMEOUT_MS);
      this.geo = point;
      this.distanceM = haversine(point.latitude, point.longitude, this.targetLatitude,
        this.targetLongitude);
      this.phase = PHASE_IDLE;
    } catch (err) {
      this.tip = (err as Error).message;
      this.phase = PHASE_IDLE;
    }
  }

  /* ==================== 打卡主流程 ==================== */

  /** 1. 申请挑战码 */
  async beginCheckin(): Promise<void> {
    if (this.phase === PHASE_LOCATING || this.phase === PHASE_RECORDING ||
      this.phase === PHASE_UPLOADING) {
      return;
    }
    this.tip = '';
    // 有坐标的任务：每次开始打卡都重新定位一次，避免拿几分钟前的旧坐标
    if (this.hasLocation) {
      this.phase = PHASE_LOCATING;
      try {
        const context: common.UIAbilityContext =
          this.getUIContext().getHostContext() as common.UIAbilityContext;
        const granted: boolean = await ensureLocationPermission(context);
        if (!granted) {
          this.tip = '没拿到定位权限，请在系统设置里允许"位置信息"后再打卡';
          this.phase = PHASE_IDLE;
          return;
        }
        const point: GeoPoint = await getCurrentGeoPoint(LOCATE_TIMEOUT_MS);
        this.geo = point;
        this.distanceM = haversine(point.latitude, point.longitude, this.targetLatitude,
          this.targetLongitude);
      } catch (err) {
        this.tip = (err as Error).message;
        this.phase = PHASE_IDLE;
        return;
      }
    }
    await this.requestChallenge();
  }

  /** 拿挑战码（重新申请会作废旧码） */
  async requestChallenge(): Promise<void> {
    this.phase = PHASE_LOCATING;
    this.tip = '';
    try {
      const challenge: VoiceChallenge = await getVoiceChallenge(this.taskId);
      this.challenge = challenge;
      this.failCount = 0;
      this.remainSec = challenge.ttlSeconds;
      this.startCountdown();
      this.phase = PHASE_CHALLENGE;
    } catch (err) {
      this.phase = PHASE_IDLE;
      await this.handleError(err);
    }
  }

  /** 60 秒倒计时，走完就把挑战码作废，逼用户重新申请 */
  startCountdown(): void {
    this.stopCountdown();
    this.countdownTimer = setInterval(() => {
      if (this.remainSec <= 1) {
        this.remainSec = 0;
        this.stopCountdown();
        if (this.phase === PHASE_CHALLENGE) {
          this.challenge = undefined;
          this.phase = PHASE_IDLE;
          this.tip = '挑战码已过期，请重新点"开始打卡"';
        }
        return;
      }
      this.remainSec = this.remainSec - 1;
    }, 1000);
  }

  stopCountdown(): void {
    if (this.countdownTimer !== -1) {
      clearInterval(this.countdownTimer);
      this.countdownTimer = -1;
    }
  }

  /** 2. 录音并提交 */
  async startRecord(): Promise<void> {
    if (this.challenge === undefined || this.phase !== PHASE_CHALLENGE) {
      return;
    }
    this.tip = '';
    this.phase = PHASE_RECORDING;
    try {
      const micOk: boolean = await this.ensureMicPermission();
      if (!micOk) {
        this.tip = '没拿到麦克风权限，请在系统设置里允许麦克风后再打卡';
        this.phase = PHASE_CHALLENGE;
        return;
      }
      const recorded: RecordedWav = await recordWav(RECORD_MS);
      if (recorded.pcmBytes <= 0) {
        this.tip = '没录到声音，请检查麦克风后重试';
        this.phase = PHASE_CHALLENGE;
        return;
      }
      await this.upload(recorded.wav);
    } catch (err) {
      this.phase = PHASE_CHALLENGE;
      this.tip = (err as Error).message;
    }
  }

  /** 3. 上传音频 + 坐标 */
  async upload(wav: ArrayBuffer): Promise<void> {
    const challenge: VoiceChallenge | undefined = this.challenge;
    if (challenge === undefined) {
      this.phase = PHASE_IDLE;
      this.tip = '挑战码已失效，请重新开始打卡';
      return;
    }
    this.phase = PHASE_UPLOADING;
    try {
      const geo: GeoPoint | undefined = this.geo;
      const result: VoiceCheckinResult = await submitVoiceCheckin({
        taskId: this.taskId,
        nonce: challenge.nonce,
        digits: challenge.digits,
        wav: wav,
        latitude: this.hasLocation && geo !== undefined ? geo.latitude : undefined,
        longitude: this.hasLocation && geo !== undefined ? geo.longitude : undefined,
        accuracy: this.hasLocation && geo !== undefined ? geo.accuracy : undefined,
        isMock: this.hasLocation && geo !== undefined ? geo.isMock : undefined
      });
      this.result = result;
      this.stopCountdown();
      this.phase = PHASE_DONE;
    } catch (err) {
      await this.handleError(err);
    }
  }

  /* ==================== 错误分流 ==================== */

  async handleError(err: Object): Promise<void> {
    if (isUnauthorized(err)) {
      await gotoLogin(this.getUIContext());
      return;
    }
    const status: number = errorStatus(err);
    const msg: string = (err as Error).message;
    this.tip = msg;
    if (status === 410 || status === 429) {
      // 挑战码失效 / 失败次数超限：必须重新申请
      this.challenge = undefined;
      this.stopCountdown();
      this.phase = PHASE_IDLE;
      return;
    }
    if (status === 422) {
      // 声纹没通过：同一个 nonce 还能重录（后端允许 3 次）
      this.failCount = this.failCount + 1;
      this.phase = PHASE_CHALLENGE;
      return;
    }
    if (status === 400) {
      if (this.challenge !== undefined) {
        // 位置类失败不消耗次数，能不能重提由后端定；挑战码还在就给重录入口
        this.phase = PHASE_CHALLENGE;
      } else {
        this.phase = PHASE_IDLE;
      }
      return;
    }
    if (status === 409) {
      // 409 有三种：已完成打卡 / 考勤还没开始 / 考勤已结束 —— 都是"现在不能打"，直接停下
      // 只有"这段录音已经提交过"才是可以重录的
      if (msg.indexOf('录音') >= 0 && msg.indexOf('提交过') >= 0) {
        this.phase = PHASE_CHALLENGE;
        return;
      }
      this.challenge = undefined;
      this.stopCountdown();
      this.phase = PHASE_IDLE;
      return;
    }
    // 其它（网络错误 status=0 / 500）留在原阶段，让用户重试
    this.phase = this.challenge !== undefined ? PHASE_CHALLENGE : PHASE_IDLE;
  }

  /* ==================== 权限 ==================== */

  async ensureMicPermission(): Promise<boolean> {
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const permissions: Permissions[] = ['ohos.permission.MICROPHONE'];
      const result = await atManager.requestPermissionsFromUser(context, permissions);
      return result.authResults.length > 0 && result.authResults[0] === 0;
    } catch (err) {
      console.error(`申请麦克风权限失败: ${JSON.stringify(err)}`);
      return false;
    }
  }

  /* ==================== 工具 ==================== */

  toast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
    } catch (err) {
      console.warn(`提示显示失败: ${JSON.stringify(err)}`);
    }
  }

  back(): void {
    try {
      this.getUIContext().getRouter().back();
    } catch (err) {
      console.error(`返回失败: ${JSON.stringify(err)}`);
    }
  }

  /** 距离文案：没定位到就不显示距离，只显示"不限位置"或地址 */
  distanceText(): string {
    if (!this.hasLocation) {
      return '不限位置';
    }
    if (this.distanceM < 0) {
      return '定位中…';
    }
    return formatDistance(this.distanceM);
  }

  inRange(): boolean {
    if (!this.hasLocation || this.distanceM < 0) {
      return false;
    }
    return this.distanceM <= this.radiusM;
  }

  /** 挑战码读法："3 8 1 5" → 大字显示，便于用户照着念 */
  digitsSpaced(): string {
    const challenge: VoiceChallenge | undefined = this.challenge;
    if (challenge === undefined) {
      return '';
    }
    const parts: string[] = [];
    for (let i = 0; i < challenge.digits.length; i++) {
      parts.push(challenge.digits.charAt(i));
    }
    return parts.join(' ');
  }

  busy(): boolean {
    return this.phase === PHASE_LOCATING || this.phase === PHASE_RECORDING ||
      this.phase === PHASE_UPLOADING;
  }

  /* ==================== 界面 ==================== */

  @Builder
  header() {
    Row({ space: 4 }) {
      Text('‹')
        .fontSize(26)
        .fontColor('#333333')
        .width(32)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.back();
        })
      Text('打卡')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
      Blank()
    }
    .width('100%')
    .height(56)
    .padding({ left: 8, right: 16 })
    .backgroundColor(Color.White)
  }

  /** 任务信息卡片：标题、类型、时间窗、地点、距离 */
  @Builder
  taskCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(this.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .maxLines(2)
        Text(checkTypeText(this.checkType))
          .fontSize(11)
          .fontColor('#0A59F7')
          .backgroundColor('#E8F0FF')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(4)
      }
      .width('100%')

      Text(`时间窗 ${formatTaskTime(this.startAt)} ~ ${formatTaskTime(this.endAt)}`)
        .fontSize(12)
        .fontColor('#999999')
        .width('100%')

      Row({ space: 8 }) {
        Text(this.hasLocation ? '📍' : '🌐')
          .fontSize(13)
        Text(this.hasLocation ?
          (this.address.length > 0 ? this.address : '打卡点') : '不限位置')
          .fontSize(12)
          .fontColor('#666666')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.hasLocation) {
          Text(this.distanceText())
            .fontSize(12)
            .fontColor(this.inRange() ? '#37B24D' : '#E84026')
        }
      }
      .width('100%')

      if (this.hasLocation) {
        Text(this.inRange() ?
          `距离打卡点 ${this.distanceText()}，在允许的 ${this.radiusM} 米范围内` :
          `距离打卡点 ${this.distanceText()}，需要走到 ${this.radiusM} 米范围内`)
          .fontSize(11)
          .fontColor('#999999')
          .width('100%')
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Color.White)
    .borderRadius(14)
  }

  /** 挑战码卡片：4 位数字 + 倒计时 */
  @Builder
  challengeCard() {
    Column({ space: 12 }) {
      Text('请匀速朗读下面 4 个数字')
        .fontSize(14)
        .fontColor('#666666')
      Text(this.digitsSpaced())
        .fontSize(44)
        .fontWeight(FontWeight.Bold)
        .fontColor('#0A59F7')
        .letterSpacing(6)
      Text('每个数字之间停顿约 0.2 秒，总时长 3~6 秒')
        .fontSize(12)
        .fontColor('#999999')
      Row({ space: 6 }) {
        Text('挑战码剩余')
          .fontSize(12)
          .fontColor('#999999')
        Text(`${this.remainSec} 秒`)
          .fontSize(12)
          .fontColor(this.remainSec <= 10 ? '#E84026' : '#37B24D')
      }
      if (this.failCount > 0) {
        Text(`已经失败 ${this.failCount} 次，同一个挑战码最多 3 次，第 4 次要重新获取`)
          .fontSize(11)
          .fontColor('#E84026')
          .width('100%')
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .padding(20)
    .backgroundColor(Color.White)
    .borderRadius(14)
  }

  @Builder
  successCard() {
    Column({ space: 10 }) {
      Text('✅')
        .fontSize(44)
      Text('打卡成功')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#37B24D')
      if (this.result !== undefined) {
        Text(`打卡时间 ${formatTaskTime(this.result.checkedAt)}`)
          .fontSize(13)
          .fontColor('#666666')
        if (this.result.locationVerified && this.result.distanceM !== null) {
          Text(`距离打卡点 ${formatDistance(this.result.distanceM)}（允许 ${this.result.radiusM} 米）`)
            .fontSize(13)
            .fontColor('#666666')
        } else {
          Text('本次任务不限位置')
            .fontSize(13)
            .fontColor('#666666')
        }
        Text(`声纹平均分 ${(this.result.avgScore * 100).toFixed(1)} 分，` +
          `最低分 ${(this.result.minScore * 100).toFixed(1)} 分`)
          .fontSize(12)
          .fontColor('#999999')
        Text(`识别到数字 ${this.result.detectedDigits}`)
          .fontSize(12)
          .fontColor('#999999')
      }
    }
    .width('100%')
    .padding(22)
    .backgroundColor(Color.White)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Column() {
      this.header()

      Scroll() {
        Column({ space: 12 }) {
          this.taskCard()

          if (this.phase === PHASE_DONE) {
            this.successCard()
            Button('返回我的考勤')
              .width('100%')
              .height(44)
              .fontColor(Color.White)
              .backgroundColor('#0A59F7')
              .onClick(() => {
                this.back();
              })
          } else {
            if (this.phase === PHASE_CHALLENGE || this.phase === PHASE_RECORDING ||
              this.phase === PHASE_UPLOADING) {
              this.challengeCard()
            }

            // 主操作按钮
            if (this.phase === PHASE_IDLE) {
              Button('开始打卡')
                .width('100%')
                .height(46)
                .fontColor(Color.White)
                .backgroundColor('#0A59F7')
                .onClick(() => {
                  this.beginCheckin().catch((err: Error) => {
                    this.tip = err.message;
                  });
                })
            } else if (this.phase === PHASE_LOCATING) {
              Row({ space: 8 }) {
                LoadingProgress()
                  .width(18)
                  .height(18)
                Text('正在定位 / 获取挑战码…')
                  .fontSize(14)
                  .fontColor('#666666')
              }
              .height(46)
            } else if (this.phase === PHASE_CHALLENGE) {
              Button('开始录音')
                .width('100%')
                .height(46)
                .fontColor(Color.White)
                .backgroundColor('#0A59F7')
                .onClick(() => {
                  this.startRecord().catch((err: Error) => {
                    this.tip = err.message;
                  });
                })
              Button('重新获取挑战码')
                .width('100%')
                .height(40)
                .fontSize(13)
                .fontColor('#0A59F7')
                .backgroundColor('#E8F0FF')
                .onClick(() => {
                  this.requestChallenge().catch((err: Error) => {
                    this.tip = err.message;
                  });
                })
            } else if (this.phase === PHASE_RECORDING) {
              Column({ space: 8 }) {
                Text('🎤 正在录音…请匀速念出上面的数字')
                  .fontSize(14)
                  .fontColor('#0A59F7')
                Text('4.5 秒后自动上传，念完请保持安静')
                  .fontSize(12)
                  .fontColor('#999999')
                LoadingProgress()
                  .width(28)
                  .height(28)
              }
              .width('100%')
              .padding(16)
              .backgroundColor(Color.White)
              .borderRadius(14)
            } else if (this.phase === PHASE_UPLOADING) {
              Column({ space: 8 }) {
                Text('正在校验声纹和位置，请稍候…')
                  .fontSize(14)
                  .fontColor('#0A59F7')
                LoadingProgress()
                  .width(28)
                  .height(28)
              }
              .width('100%')
              .padding(16)
              .backgroundColor(Color.White)
              .borderRadius(14)
            }
          }

          if (this.tip.length > 0) {
            Text(this.tip)
              .fontSize(13)
              .fontColor('#E84026')
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ left: 8, right: 8 })
          }

          Text('打卡需要念 4 个数字并比对声纹；任务有打卡点时还会校验位置。' +
            '只有 401 才表示登录失效，其它失败都可以直接重试。')
            .fontSize(11)
            .fontColor('#AAAAAA')
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 6 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F1F3F5')
  }
}
