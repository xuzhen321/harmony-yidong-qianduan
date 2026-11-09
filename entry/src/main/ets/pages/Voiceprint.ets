import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import {
  DIGIT_TAGS,
  EnrollResult,
  VoiceprintStatus,
  VP_ACTIVE,
  VP_REVOKED,
  enrollDigit,
  getVoiceprintStatus,
  statusText
} from '../api/Voiceprint';
import { UserInfo, getUserInfo } from '../api/UserLogin';
import { SessionUser, getRole, getToken, getUserName, gotoLogin, roleText, saveProfile } from '../utils/AuthStore';
import { isUnauthorized } from '../utils/HttpUtil';
import { RecordedWav, recordWav } from '../utils/Recorder';

/** 一次录多久：文档要求 0.5~1.5 秒，取 1.4 秒留一点余量，别顶到 1.5 的边界 */
const RECORD_MS: number = 1400;
/** 每次正式开录前先等一下，让用户看清"该念哪个数字" */
const PREPARE_MS: number = 700;

/**
 * 声纹注册页（`前后端联调文档-声纹模块.md`）。
 *
 * 流程（文档 6.1 / 6.2）：
 *   进页面 → GET /voiceprint/status
 *     ├── NOT_ENROLLED / REVOKED → 10 个数字从头录
 *     ├── ENROLLING              → 只录 missingDigits 里的
 *     └── ACTIVE                 → 已完成，直接返回
 *   每录一个数字：麦克风抓 16kHz/16bit/单声道 PCM → 拼 WAV → multipart 上传
 *   录满 10 个后 readyForCheckin=true，顺便刷一次 /user/info 让 needVoiceprintEnroll 变 false
 *
 * 409 不是登录失效（同一个数字已录满 2 条 / 音频重复 / 声纹疑似别号），只提示不清 token。
 */
@Entry
@ComponentV2
struct Voiceprint {
  @Local loading: boolean = false;
  @Local status: string = '';
  @Local digitCount: number = 0;
  /** 还缺哪些数字，后端给的是 '0' ~ '9' 这样的字符 */
  @Local missingDigits: string[] = [];
  @Local ready: boolean = false;
  @Local enrolledAt: string = '';
  @Local tip: string = '';
  /** 正在录音 */
  @Local recording: boolean = false;
  /** 正在上传 */
  @Local uploading: boolean = false;
  /** 正在录哪个数字，-1 表示没有 */
  @Local currentDigit: number = -1;
  /** 准备阶段的提示语 */
  @Local hint: string = '';

  onPageShow(): void {
    this.loadStatus();
  }

  /* ==================== 数据 ==================== */

  async loadStatus(): Promise<void> {
    if (getToken().length === 0) {
      await gotoLogin(this.getUIContext());
      return;
    }
    this.loading = true;
    try {
      const data: VoiceprintStatus = await getVoiceprintStatus();
      this.status = data.status;
      this.digitCount = data.digitCount;
      this.missingDigits = data.missingDigits ? data.missingDigits : [];
      this.ready = data.readyForCheckin === true;
      this.enrolledAt = data.enrolledAt ? data.enrolledAt : '';
      this.loading = false;
      if (this.ready) {
        // 录满 10 个之后 /user/info 的 needVoiceprintEnroll 会变成 false，本地同步一下
        await this.syncUserInfo();
      }
    } catch (err) {
      this.loading = false;
      await this.handleError(err);
    }
  }

  /** 把 needVoiceprintEnroll 的最新值写回 AuthStore，别的页面就不用再猜了 */
  async syncUserInfo(): Promise<void> {
    try {
      const info: UserInfo = await getUserInfo();
      const user: SessionUser = {
        userId: info.userId,
        userName: info.userName,
        nickName: info.nickName ? info.nickName : '',
        role: info.role,
        needVoiceprintEnroll: info.needVoiceprintEnroll === true
      };
      saveProfile(user);
    } catch (err) {
      // 同步失败不影响注册结果，下次进"我的"页还会再拉一次
      console.warn(`同步用户信息失败: ${(err as Error).message}`);
    }
  }

  /* ==================== 录音 + 上传 ==================== */

  async startRecord(digit: number): Promise<void> {
    if (this.recording || this.uploading) {
      return;
    }
    if (this.status.length === 0) {
      // 还没拉到状态就点，缺哪个数字都不知道，先让状态加载完
      this.loadStatus().catch((err: Error) => {
        this.tip = err.message;
      });
      return;
    }
    if (this.ready) {
      this.toast('10 个数字都录完了');
      return;
    }
    if (!this.isMissing(`${digit}`)) {
      // 已经录过的数字：文档说没有单独删除模板的接口，只能找管理员整体重置
      this.tip = `数字 ${digit} 已经录过了。每个数字最多 2 条，要重录请让管理员重置声纹。`;
      return;
    }

    this.tip = '';
    this.recording = true;
    this.currentDigit = digit;
    this.hint = `请念：${digit}`;

    // 先给用户 0.7 秒看清提示，再真正开录，减少"还没开口录音就结束了"
    setTimeout(() => {
      this.captureAndUpload(digit).catch((err: Error) => {
        this.recording = false;
        this.uploading = false;
        this.currentDigit = -1;
        this.hint = '';
        this.tip = err.message;
      });
    }, PREPARE_MS);
  }

  /** 真正抓音频 + 上传；和 startRecord 拆开，是因为要先停在"请念 X"的提示上 */
  async captureAndUpload(digit: number): Promise<void> {
    const granted: boolean = await this.ensureMicPermission();
    if (!granted) {
      this.resetRecordingState();
      this.tip = '没有麦克风权限，录不了音。请到系统设置里给"测试软件"打开麦克风权限。';
      return;
    }

    let pcmBytes: number = 0;
    let wavData: ArrayBuffer = new ArrayBuffer(0);
    try {
      const recorded: RecordedWav = await recordWav(RECORD_MS);
      pcmBytes = recorded.pcmBytes;
      wavData = recorded.wav;
    } catch (err) {
      this.resetRecordingState();
      this.tip = `录音失败：${(err as Error).message}`;
      return;
    }

    this.recording = false;
    this.hint = '';

    if (pcmBytes < 16000) {
      // 16000 字节 ≈ 0.5 秒，太少说明根本没录到
      this.resetRecordingState();
      this.tip = '几乎没录到声音，请对着麦克风再念一次';
      return;
    }

    this.uploading = true;
    try {
      const result: EnrollResult = await enrollDigit(`DIGIT_${digit}`, wavData);
      this.resetRecordingState();
      this.toast(`数字 ${digit} 录入成功，质量分 ${result.quality}`);
      await this.loadStatus();
    } catch (err) {
      this.resetRecordingState();
      await this.handleError(err);
    }
  }

  resetRecordingState(): void {
    this.recording = false;
    this.uploading = false;
    this.currentDigit = -1;
    this.hint = '';
  }

  /** 申请麦克风权限：已经授权过会直接返回 true，不会反复弹框 */
  async ensureMicPermission(): Promise<boolean> {
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
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

  async handleError(err: Object): Promise<void> {
    if (isUnauthorized(err)) {
      await gotoLogin(this.getUIContext());
      return;
    }
    // 400（格式 / 太短 / 太长 / 质量低）和 409（重复 / 录满 2 条 / 疑似别号）都把后端 msg 直接给用户
    this.tip = (err as Error).message;
  }

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

  /** DIGIT_3 → 3（DIGIT_TAGS 的下标刚好就是数字本身） */
  digitOf(tag: string): number {
    return DIGIT_TAGS.indexOf(tag);
  }

  /** 这个数字还缺着吗 */
  isMissing(digit: string): boolean {
    return this.missingDigits.indexOf(digit) >= 0;
  }

  /** 这个数字录过了吗 */
  isDone(tag: string): boolean {
    if (this.status.length === 0) {
      // 状态还没请求回来，别把 10 个格子都画成"已录"
      return false;
    }
    if (this.ready) {
      return true;
    }
    return !this.isMissing(`${this.digitOf(tag)}`);
  }

  isCurrent(tag: string): boolean {
    return this.currentDigit === this.digitOf(tag);
  }

  cellColor(tag: string): string {
    if (this.isCurrent(tag)) {
      return '#0A59F7';
    }
    return this.isDone(tag) ? '#37B24D' : '#F0F2F5';
  }

  cellTextColor(tag: string): string {
    return this.isDone(tag) || this.isCurrent(tag) ? '#FFFFFF' : '#333333';
  }

  cellLabel(tag: string): string {
    if (this.isCurrent(tag)) {
      return this.uploading ? '上传中' : '录音中';
    }
    return this.isDone(tag) ? '已录' : '待录';
  }

  statusColor(): string {
    if (this.status === VP_ACTIVE) {
      return '#37B24D';
    }
    if (this.status === VP_REVOKED) {
      return '#E84026';
    }
    return '#0A59F7';
  }

  /** 缺的数字拼成 "3、7" 这种好读的样子 */
  missingText(): string {
    if (this.missingDigits.length === 0) {
      return '无';
    }
    return this.missingDigits.join('、');
  }

  userNameText(): string {
    const name: string = getUserName();
    return name.length > 0 ? name : '当前账号';
  }

  /* ==================== 界面 ==================== */

  build() {
    Column() {
      // 顶部标题栏
      Row() {
        Text('‹')
          .fontSize(26)
          .fontColor('#333333')
          .width(32)
          .onClick(() => {
            this.back();
          })
        Text('声纹注册')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
        Blank()
        if (this.loading || this.uploading) {
          LoadingProgress()
            .width(20)
            .height(20)
        }
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .backgroundColor(Color.White)

      Scroll() {
        Column({ space: 14 }) {
          // ---- 状态卡片 ----
          Column({ space: 12 }) {
            Row() {
              Text(statusText(this.status))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.statusColor())
              Blank()
              Text(`${this.digitCount} / 10`)
                .fontSize(14)
                .fontColor('#666666')
            }
            .width('100%')

            // 进度条：不引入额外组件，用两层 Row 叠宽度就够了
            Stack({ alignContent: Alignment.Start }) {
              Row()
                .width('100%')
                .height(6)
                .borderRadius(3)
                .backgroundColor('#EEF0F3')
              Row()
                .width(`${this.digitCount * 10}%`)
                .height(6)
                .borderRadius(3)
                .backgroundColor(this.statusColor())
            }
            .width('100%')
            .height(6)

            Row() {
              Text('还缺')
                .fontSize(13)
                .fontColor('#666666')
              Text(this.missingText())
                .fontSize(13)
                .fontColor('#333333')
                .layoutWeight(1)
                .margin({ left: 6 })
            }
            .width('100%')

            if (this.enrolledAt.length > 0) {
              Text(`完成时间：${this.enrolledAt}`)
                .fontSize(12)
                .fontColor('#37B24D')
                .width('100%')
            }

            if (this.status === VP_REVOKED) {
              Text('管理员重置了你的声纹，之前的录音都不能再用，需要 10 个数字全部重录。')
                .fontSize(12)
                .fontColor('#E84026')
                .width('100%')
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(12)

          // ---- 录音状态 / 提示 ----
          if (this.recording) {
            Column({ space: 8 }) {
              Row({ space: 8 }) {
                LoadingProgress()
                  .width(22)
                  .height(22)
                  .color('#0A59F7')
                Text(this.hint.length > 0 ? this.hint : '正在录音…')
                  .fontSize(15)
                  .fontColor('#0A59F7')
                  .fontWeight(FontWeight.Medium)
              }

              Text('只念一个数字，前后留一点停顿，别连读')
                .fontSize(12)
                .fontColor('#999999')
            }
            .width('100%')
            .padding(16)
            .backgroundColor('#E8F0FF')
            .borderRadius(12)
          }

          if (this.uploading) {
            Row({ space: 8 }) {
              LoadingProgress()
                .width(20)
                .height(20)
                .color('#0A59F7')
              Text('正在上传并校验录音…')
                .fontSize(14)
                .fontColor('#0A59F7')
            }
            .width('100%')
            .padding(16)
            .backgroundColor('#E8F0FF')
            .borderRadius(12)
          }

          // ---- 10 个数字 ----
          Column({ space: 12 }) {
            Text('点一个数字，跟着念一次')
              .fontSize(15)
              .fontColor('#333333')
              .width('100%')

            Grid() {
              ForEach(DIGIT_TAGS, (tag: string) => {
                GridItem() {
                  Column({ space: 6 }) {
                    Stack() {
                      if (this.isCurrent(tag) && this.uploading) {
                        LoadingProgress()
                          .width(22)
                          .height(22)
                          .color('#FFFFFF')
                      } else {
                        Text(`${this.digitOf(tag)}`)
                          .fontSize(20)
                          .fontWeight(FontWeight.Medium)
                          .fontColor(this.cellTextColor(tag))
                      }
                    }
                    .width(48)
                    .height(48)
                    .borderRadius(24)
                    .backgroundColor(this.cellColor(tag))

                    Text(this.cellLabel(tag))
                      .fontSize(11)
                      .fontColor('#999999')
                  }
                  .width('100%')
                  .height('100%')
                  .justifyContent(FlexAlign.Center)
                }
                .onClick(() => {
                  this.startRecord(this.digitOf(tag)).catch((err: Error) => {
                    this.resetRecordingState();
                    this.tip = err.message;
                  });
                })
              }, (tag: string) => tag)
            }
            .columnsTemplate('1fr 1fr 1fr 1fr 1fr')
            .rowsTemplate('1fr 1fr')
            .columnsGap(6)
            .rowsGap(6)
            .width('100%')
            .height(168)

            Text('每次录 1.4 秒；每个数字最多 2 条，录错了只能让管理员整体重置。')
              .fontSize(11)
              .fontColor('#999999')
              .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(12)

          // ---- 已完成 ----
          if (this.ready) {
            Column({ space: 10 }) {
              Text('🎉 10 个数字都录完了')
                .fontSize(15)
                .fontColor('#37B24D')
                .fontWeight(FontWeight.Medium)
                .width('100%')
              Text('现在可以正常使用考勤打卡了。如果要重录，请让管理员先重置你的声纹。')
                .fontSize(12)
                .fontColor('#666666')
                .width('100%')
              Button('返回')
                .width('100%')
                .height(44)
                .onClick(() => {
                  this.back();
                })
            }
            .width('100%')
            .padding(16)
            .backgroundColor('#EDFBF1')
            .borderRadius(12)
          } else {
            Button(this.recording ? '录音中…' : (this.uploading ? '上传中…' : '刷新状态'))
              .width('100%')
              .height(44)
              .backgroundColor(Color.White)
              .fontColor('#0A59F7')
              .enabled(!this.recording && !this.uploading && !this.loading)
              .onClick(() => {
                this.loadStatus().catch((err: Error) => {
                  this.tip = err.message;
                });
              })
          }

          // ---- 错误 / 提示 ----
          if (this.tip.length > 0) {
            Text(this.tip)
              .fontSize(13)
              .fontColor('#E84026')
              .width('100%')
              .padding(12)
              .backgroundColor('#FFF1F0')
              .borderRadius(8)
          }

          Text(`账号：${this.userNameText()}　角色：${roleText(getRole())}`)
            .fontSize(11)
            .fontColor('#BBBBBB')
            .margin({ top: 4, bottom: 16 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F1F3F5')
  }
}
