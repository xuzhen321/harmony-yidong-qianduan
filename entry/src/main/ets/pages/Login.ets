import { getUserInfo, login, LoginRequest, LoginResult, UserInfo } from '../api/UserLogin';
import { FaceAuthOutcome, isFaceAvailable, verifyFace } from '../utils/BiometricAuth';
import { clearLogin, loadLogin, saveLogin, SavedLogin } from '../utils/CredentialStore';
import { getToken, saveProfile, saveSession, SessionUser } from '../utils/AuthStore';
import { DEFAULT_BASE_URL } from '../utils/HttpUtil';

/**
 * 登录页（对应联调文档第 4.1 节）。
 *
 * 基础流程：
 *   1. 校验入参（userName 非空/≤32，password 6~32）
 *   2. POST /user/login
 *   3. code === 1 → 保存 token + userId + userName + nickName + role → 进"我的"
 *   4. 失败 → 直接展示后端 msg（"用户名或密码错误"也在这一页显示，不跳转）
 *
 * 人脸登录（纯前端，后端零改动）：
 *   - 首次手动登录成功后，问用户要不要在这台设备开启；
 *   - 开启 = 先过一遍系统人脸（绑定确认）+ 把账号密码加密存进系统保险箱（Asset + 设备绑定）；
 *   - 以后打开登录页，账号已填好，点「人脸登录」→ 系统人脸验证 → 通过才解密密码 → 照常调 /user/login；
 *   - 换手机、重装、改密码、退出登录 → 凭证作废，回到手动登录。
 *
 * 特别注意：登录接口返回 401 表示"账号或密码错误"，是正常业务失败，
 * 不能触发"清 token 跳登录页"的全局逻辑（我们本来就在登录页）。
 */
@Entry
@ComponentV2
struct Login {
  @Local userName: string = '';
  @Local password: string = '';
  @Local loading: boolean = false;
  @Local tip: string = '';

  /** 本机是否支持系统人脸验证（ATL3 → ATL2 自动降级探测） */
  @Local faceOk: boolean = false;
  /** 本机保险箱里保存的凭证（设备不匹配/换机时为 undefined） */
  @Local saved: SavedLogin | undefined = undefined;
  /** 人脸验证进行中，防止连点 */
  @Local faceBusy: boolean = false;
  /** 登录成功后询问"是否开启人脸登录"的面板 */
  @Local askFace: boolean = false;
  @Local pendingUserId: number = 0;

  onPageShow(): void {
    this.faceOk = isFaceAvailable();
    // 文档 7.1：本地还有 token 就先验证一下，有效直接进"我的"，省得每次输密码
    this.tryAutoLogin();
    this.refreshSaved().catch((err: Error) => {
      console.warn(`读取人脸登录凭证失败: ${err.message}`);
    });
  }

  /** 读一次凭证：有就顺手把用户名填上，密码留空等刷脸 */
  async refreshSaved(): Promise<void> {
    const credential: SavedLogin | undefined = await loadLogin();
    this.saved = credential;
    if (credential !== undefined) {
      this.userName = credential.userName;
    }
  }

  async tryAutoLogin(): Promise<void> {
    if (getToken().length === 0 || this.loading) {
      return;
    }
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
      await this.gotoMine();
    } catch (err) {
      // token 失效时 HttpUtil 已经清掉本地 token 了，留在登录页让用户重新登录即可
      this.tip = '';
    }
  }

  /** 人脸登录：验证通过才把保险箱里的密码填进内存，然后走和手动登录完全一样的 /user/login */
  async doFaceLogin(): Promise<void> {
    const credential: SavedLogin | undefined = this.saved;
    if (credential === undefined || this.faceBusy || this.loading) {
      return;
    }
    this.faceBusy = true;
    this.tip = '';
    const outcome: FaceAuthOutcome = await verifyFace('人脸登录');
    this.faceBusy = false;
    if (!outcome.ok) {
      // 取消也算失败，但提示用灰色的"已取消"，别把用户吓到
      this.tip = outcome.message;
      return;
    }
    this.userName = credential.userName;
    this.password = credential.password;
    await this.doLogin(true);
  }

  /**
   * @param fromFace 是否由人脸登录触发：是的话登录失败要清掉凭证（密码可能已被管理员重置）
   */
  async doLogin(fromFace: boolean = false): Promise<void> {
    if (this.loading) {
      return;
    }

    // 前端先做一遍文档里的入参校验，少一次网络往返
    const name: string = this.userName.trim();
    if (name.length === 0) {
      this.tip = '用户名不能为空';
      return;
    }
    if (name.length > 32) {
      this.tip = '用户名长度不能超过 32 个字符';
      return;
    }
    if (this.password.length < 6 || this.password.length > 32) {
      this.tip = '密码长度必须在 6 到 32 个字符之间';
      return;
    }

    this.loading = true;
    this.tip = '';
    try {
      const params: LoginRequest = { userName: name, password: this.password };
      const result: LoginResult = await login(params);

      const user: SessionUser = {
        userId: result.userId,
        userName: result.userName,
        nickName: result.nickName ? result.nickName : result.userName,
        role: result.role,
        needVoiceprintEnroll: result.needVoiceprintEnroll === true
      };
      saveSession(result.token, user);
      this.loading = false;

      if (user.needVoiceprintEnroll === true) {
        // 文档 4.1：true 表示 10 个数字没录齐，打卡相关接口会被 403 拦住
        this.toast('声纹还没注册，打卡前需要先录满 10 个数字');
      }

      // 账号换了或者还没存过凭证 → 问一句要不要开启人脸登录
      const needAsk: boolean = this.faceOk && !fromFace &&
        (this.saved === undefined || this.saved.userName !== name);
      if (needAsk) {
        this.pendingUserId = user.userId;
        this.askFace = true;
        return;
      }
      await this.gotoMine();
    } catch (err) {
      // 这里的 message 就是后端 msg：401 → 用户名或密码错误；400 → 参数不合法
      this.tip = (err as Error).message;
      this.loading = false;
      if (fromFace) {
        // 保险箱里的密码已经登不上了（多半被管理员重置/自己改过），清掉免得一直失败
        await clearLogin();
        this.saved = undefined;
        this.password = '';
        this.tip = '保存的密码已失效，请手动输入新密码登录';
      }
    }
  }

  /** 面板里点「开启」：系统人脸确认 + 加密存进保险箱 */
  async enableFaceLogin(): Promise<void> {
    if (this.faceBusy) {
      return;
    }
    this.faceBusy = true;
    const outcome: FaceAuthOutcome = await verifyFace('启用人脸登录');
    if (!outcome.ok) {
      this.faceBusy = false;
      this.tip = outcome.message;
      return;
    }
    try {
      await saveLogin(this.userName.trim(), this.password, this.pendingUserId);
      await this.refreshSaved();
      this.toast('已开启，下次打开登录页点「人脸登录」就能进');
    } catch (err) {
      this.tip = `开启失败：${(err as Error).message}`;
    }
    this.faceBusy = false;
    this.askFace = false;
    await this.gotoMine();
  }

  /** 面板里点「暂不」 */
  skipFaceLogin(): void {
    this.askFace = false;
    this.gotoMine().catch((err: Error) => {
      this.tip = err.message;
    });
  }

  /** 不想用人脸了：清掉本机凭证（退出登录不清，这里才清） */
  async forgetSaved(): Promise<void> {
    await clearLogin();
    this.saved = undefined;
    this.password = '';
    this.tip = '已清除本机的人脸登录凭证';
  }

  /** 轻提示。showToast 声明了可能抛 BusinessError，包起来免得影响主流程 */
  toast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2500 });  // 弹窗提示
    } catch (err) {
      console.warn(`提示显示失败: ${JSON.stringify(err)}`);
    }
  }

  async gotoMine(): Promise<void> {
    try {
      // replaceUrl：把登录页从路由栈里换掉，返回键不会再回到登录页
      // 登录成功先进「考勤」标签页（底部栏可切到「我的」）
      await this.getUIContext().getRouter().replaceUrl({ url: 'pages/MyTasks' });
    } catch (err) {
      console.error(`进入我的页面失败: ${JSON.stringify(err)}`);
    }
  }

  @Builder
  faceAskPanel() {
    Column({ space: 12 }) { // 子组件之间的间隔为12vp
      Text('开启人脸登录')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor('#333333')

      Text(`以后在这台设备打开登录页，刷一下脸就能自动登录 ${this.userName.trim()}。`)
        .fontSize(13)
        .fontColor('#888888')
        .lineHeight(20)

      Text('账号密码会加密存在系统的应用保险箱里，本机之外用不了；换手机、改密码、退出登录都会自动失效。')
        .fontSize(12)
        .fontColor('#999999')
        .lineHeight(18)

      Row({ space: 10 }) {
        Button('暂不')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .backgroundColor('#F0F2F5')
          .fontColor('#666666')
          .enabled(!this.faceBusy)
          .onClick(() => {
            this.skipFaceLogin();
          })

        Button(this.faceBusy ? '验证中...' : '开启')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .backgroundColor('#0A59F7')
          .fontColor(Color.White)
          .enabled(!this.faceBusy)
          .onClick(() => {
            this.enableFaceLogin().catch((err: Error) => {
              this.tip = err.message;
            });
          })
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .width('100%')
    .padding(20)
    .backgroundColor(Color.White)
    .borderRadius(16)
    .margin({ left: 24, right: 24 })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Column({ space: 18 }) {
          Text('移动应用开发').fontSize(13).fontColor('#999999')

          Text('登 录')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .margin({ bottom: 4 })

          TextInput({ placeholder: '用户名（最长 32 位）', text: this.userName })
            .height(48)
            .maxLength(32)
            .onChange((value: string) => {
              this.userName = value;
            })

          TextInput({
            placeholder: this.saved !== undefined ? '已保存密码，点下方「人脸登录」即可' : '密码（6~32 位）',
            text: this.password
          })
            .height(48)
            .maxLength(32)
            .type(InputType.Password)
            .onChange((value: string) => {
              this.password = value;
            })

          // 主按钮固定是「登录」；开了人脸登录时，下面再多给一个浅色的「人脸登录」入口
          Button(this.loading ? '登录中...' : '登 录')
            .width('100%')
            .height(48)
            .backgroundColor('#0A59F7')
            .fontColor(Color.White)
            .enabled(!this.loading)
            .onClick(() => {
              this.doLogin(false).catch((err: Error) => {
                this.tip = err.message;
              });
            })

          if (this.saved !== undefined) {
            Button(this.faceBusy ? '请验证人脸...' : `人脸登录（${this.saved.userName}）`)
              .width('100%')
              .height(48)
              .fontSize(16)
              .backgroundColor('#E8F0FF')
              .fontColor('#0A59F7')
              .enabled(!this.faceBusy && !this.loading)
              .onClick(() => {
                this.doFaceLogin().catch((err: Error) => {
                  this.tip = err.message;
                });
              })

            Text('不用刷脸？上面输入密码直接登录')
              .fontSize(12)
              .fontColor('#999999')

            Text('清除本机人脸登录凭证')
              .fontSize(12)
              .fontColor('#0A59F7')
              .onClick(() => {
                this.forgetSaved().catch((err: Error) => {
                  this.tip = err.message;
                });
              })
          }

          Text(this.tip)
            .fontSize(13)
            .fontColor('#E84026')
            .width('100%')
            .textAlign(TextAlign.Center)
            .height(18)

          if (this.faceOk && this.saved === undefined) {
            Text('💡 本次登录成功后可开启人脸登录，下次刷脸就进')
              .fontSize(12)
              .fontColor('#999999')
              .width('100%')
              .textAlign(TextAlign.Center)
          }

          // 把当前请求的地址显示出来，连不上时一眼就能看出是不是 IP 填错了
          Text(`接口地址：${DEFAULT_BASE_URL}`)
            .fontSize(11)
            .fontColor('#BBBBBB')
            .margin({ top: 8 })
        }
        .width('100%')
        .padding(24)
        .backgroundColor(Color.White)
        .borderRadius(16)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 20, right: 20 })
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#F1F3F5')

      // 登录成功后的"要不要开人脸"面板
      if (this.askFace) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')

        this.faceAskPanel()
      }
    }
    .width('100%')
    .height('100%')
  }
}
