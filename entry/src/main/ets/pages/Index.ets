import { common } from '@kit.AbilityKit';
import { camera, cameraPicker } from '@kit.CameraKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { clearLogin } from '../utils/CredentialStore';
import { BottomTabs } from '../components/BottomTabs';
import {
  ChangePasswordRequest,
  UpdateNicknameRequest,
  UserInfo,
  changePassword,
  getUserInfo,
  logout,
  updateNickname
} from '../api/UserLogin';
import {
  SessionUser,
  getToken,
  gotoLogin,
  saveProfile
} from '../utils/AuthStore';
import { DEFAULT_BASE_URL, isUnauthorized } from '../utils/HttpUtil';

/**
 * "我的"页面（所有人可见）。
 *
 * 对应联调文档第 5 节 + 7.1：
 *   - 进页面 GET /user/info 拿最新昵称、角色（顺便验证 token 还有效）
 *   - PUT /user/nickname 改昵称（token 不变）
 *   - PUT /user/password 改密码（成功后所有 token 失效 → 必须回登录页）
 *   - POST /user/logout 退出（无论成败都清本地登录态回登录页）
 *   - role === 'ADMIN' 才显示"人员管理"入口（真正的权限校验在后端，普通用户直接调接口会 403）
 *
 * 头像：后端没有头像接口，所以纯本地存储——
 *   拍照 / 相册选图 → 图片落到应用沙箱 `filesDir/avatar_<userId>.jpg` → 用 PixelMap 显示。
 *   按 userId 命名，换账号登录看到的是各自的头像。
 */
@Entry
@ComponentV2
struct Index {
  @Local userId: number = 0;
  @Local userName: string = '';
  @Local nickName: string = '';
  /** true = 10 个声纹数字还没录齐，打卡前要先录 */
  @Local voiceprintPending: boolean = false;
  @Local role: string = '';
  @Local loading: boolean = false;
  @Local tip: string = '';
  @Local nickInput: string = '';
  /** 修改昵称默认收起，点行才展开输入框 */
  @Local nickPanelOpen: boolean = false;
  @Local pwdPanelOpen: boolean = false;
  @Local oldPassword: string = '';
  @Local newPassword: string = '';
  @Local confirmPassword: string = '';
  /** 本地头像；undefined = 还没设置过，显示昵称首字母 */
  @Local avatarPixel: image.PixelMap | undefined = undefined;
  /** 选图/拍照进行中，防止连点 */
  @Local avatarBusy: boolean = false;
  /** 底部「更换头像」弹层是否展开 */
  @Local avatarSheet: boolean = false;

  onPageShow(): void {
    // 从人员管理页返回时也会走这里，顺便刷新一下昵称（管理员可能刚改了自己的）
    this.loadUserInfo();
  }

  /* ==================== 数据 ==================== */

  async loadUserInfo(): Promise<void> {
    if (getToken().length === 0) {
      await gotoLogin(this.getUIContext());
      return;
    }

    this.loading = true;
    this.tip = '';
    try {
      const info: UserInfo = await getUserInfo();
      this.userId = info.userId;
      this.userName = info.userName;
      this.nickName = info.nickName ? info.nickName : '';
      this.role = info.role;
      this.voiceprintPending = info.needVoiceprintEnroll === true;
      if (this.nickInput.length === 0) {
        this.nickInput = this.nickName;
      }
      const user: SessionUser = {
        userId: this.userId,
        userName: this.userName,
        nickName: this.nickName,
        role: this.role,
        needVoiceprintEnroll: this.voiceprintPending
      };
      saveProfile(user);
      this.loading = false;
      // 头像按 userId 存在沙箱里，拿到 userId 才能定位文件
      await this.loadAvatar();
    } catch (err) {
      this.loading = false;
      await this.handleError(err);
    }
  }

  /* ==================== 头像 ==================== */

  /** 头像固定落在这个沙箱文件里，按用户分开，换账号不会串 */
  avatarPath(): string {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return `${context.filesDir}/avatar_${this.userId}.jpg`;
  }

  /** 沙箱里有文件就加载成 PixelMap 显示；没有就回落到昵称首字母 */
  async loadAvatar(): Promise<void> {
    if (this.userId <= 0) {
      return;
    }
    const path: string = this.avatarPath();
    let exists: boolean = false;
    try {
      exists = fs.accessSync(path);
    } catch (err) {
      console.warn(`检查头像文件失败: ${JSON.stringify(err)}`);
    }
    if (!exists) {
      this.avatarPixel = undefined;
      return;
    }
    try {
      // 用 PixelMap 而不是直接把路径丢给 Image：同一路径换了内容后 Image 会有缓存，
      // PixelMap 每次都是重新解码的真实内容。走 fd 比走 URI 更稳（不依赖 URI 拼接规则）。
      const avatarFile = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const source: image.ImageSource = image.createImageSource(avatarFile.fd);
      const pixel: image.PixelMap = await source.createPixelMap();
      await source.release();
      fs.closeSync(avatarFile);
      this.avatarPixel = pixel;
    } catch (err) {
      console.error(`加载头像失败: ${JSON.stringify(err)}`);
      this.avatarPixel = undefined;
    }
  }

  /** 点头像：底部弹层选 拍照 / 相册 / 恢复默认 */
  async openAvatarMenu(): Promise<void> {
    if (this.avatarBusy || this.loading) {
      return;
    }
    this.avatarSheet = true;
  }

  /** 系统相机直接写进沙箱（saveUri），不用再拷一次 */
  async pickFromCamera(): Promise<void> {
    this.avatarBusy = true;
    const path: string = this.avatarPath();
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      // saveUri 要求文件已存在且可写，先建个空文件
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.closeSync(file);

      const profile: cameraPicker.PickerProfile = {
        cameraPosition: camera.CameraPosition.CAMERA_POSITION_FRONT,
        saveUri: fileUri.getUriFromPath(path)
      };
      const result = await cameraPicker.pick(context, [cameraPicker.PickerMediaType.PHOTO], profile);
      this.avatarBusy = false;
      if (result.resultCode !== 0) {
        // 用户按了返回/取消
        return;
      }
      await this.loadAvatar();
      this.toast('头像已更新');
    } catch (err) {
      this.avatarBusy = false;
      this.tip = `拍照失败：${(err as Error).message}`;
    }
  }

  /** 相册选一张，拷进沙箱（相册给的是 media:// 这类 URI，重启后可能读不了，必须落地） */
  async pickFromAlbum(): Promise<void> {
    this.avatarBusy = true;
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const picked = await picker.select(options);
      if (picked.photoUris.length === 0) {
        this.avatarBusy = false;
        return;
      }

      const path: string = this.avatarPath();
      const sourceFile = fs.openSync(picked.photoUris[0], fs.OpenMode.READ_ONLY);
      fs.copyFileSync(sourceFile.fd, path);
      fs.closeSync(sourceFile);
      this.avatarBusy = false;
      await this.loadAvatar();
      this.toast('头像已更新');
    } catch (err) {
      this.avatarBusy = false;
      this.tip = `读取相册图片失败：${(err as Error).message}`;
    }
  }

  async removeAvatar(): Promise<void> {
    try {
      fs.unlinkSync(this.avatarPath());
    } catch (err) {
      console.warn(`删除头像文件失败: ${JSON.stringify(err)}`);
    }
    if (this.avatarPixel !== undefined) {
      await this.avatarPixel.release();
    }
    this.avatarPixel = undefined;
    this.toast('已恢复默认头像');
  }

  /* ==================== 操作 ==================== */

  async doSaveNickName(): Promise<void> {
    const name: string = this.nickInput.trim();
    if (name.length === 0) {
      this.tip = '昵称不能为空';
      return;
    }
    if (name.length > 32) {
      this.tip = '昵称长度不能超过 32 个字符';
      return;
    }
    if (this.loading) {
      return;
    }

    this.loading = true;
    this.tip = '';
    try {
      const params: UpdateNicknameRequest = { nickName: name };
      await updateNickname(params);
    } catch (err) {
      this.loading = false;
      await this.handleError(err);
      return;
    }

    // 文档 5.2：改昵称不会让 token 失效，本地同步一下就行，不用重新登录
    this.loading = false;
    this.nickName = name;
    const user: SessionUser = {
      userId: this.userId,
      userName: this.userName,
      nickName: name,
      role: this.role
    };
    saveProfile(user);
    this.toast('昵称已更新');
  }

  async doChangePassword(): Promise<void> {
    if (this.loading) {
      return;
    }
    const oldPwd: string = this.oldPassword;
    const newPwd: string = this.newPassword;
    if (oldPwd.length < 6 || oldPwd.length > 32) {
      this.tip = '原密码长度必须在 6 到 32 个字符之间';
      return;
    }
    if (newPwd.length < 6 || newPwd.length > 32) {
      this.tip = '新密码长度必须在 6 到 32 个字符之间';
      return;
    }
    if (newPwd === oldPwd) {
      this.tip = '新密码不能与原密码相同';
      return;
    }
    if (newPwd !== this.confirmPassword) {
      this.tip = '两次输入的新密码不一致';
      return;
    }

    this.loading = true;
    this.tip = '';
    try {
      const params: ChangePasswordRequest = { oldPassword: oldPwd, newPassword: newPwd };
      await changePassword(params);
    } catch (err) {
      this.loading = false;
      await this.handleError(err);
      return;
    }

    // 文档 5.1：改密码后该用户所有 token 立即失效（包括当前这个），必须回登录页
    this.loading = false;
    this.oldPassword = '';
    this.newPassword = '';
    this.confirmPassword = '';
    // 密码变了，人脸登录里存的旧密码必然登不上，直接作废
    await clearLogin();
    this.toast('密码已修改，请重新登录；人脸登录需要重新开启');
    await gotoLogin(this.getUIContext());
  }

  async doLogout(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    try {
      await logout();
    } catch (err) {
      // 文档 7.3：退出接口失败也照样清本地登录态，不能让用户卡在登录状态
      console.warn(`退出接口调用失败（不影响本地退出）: ${(err as Error).message}`);
    }
    this.loading = false;
    this.toast('已退出登录');
    await gotoLogin(this.getUIContext());
  }

  async openVoiceprint(): Promise<void> {
    try {
      await this.getUIContext().getRouter().pushUrl({ url: 'pages/Voiceprint' });
    } catch (err) {
      console.error(`打开声纹注册失败: ${JSON.stringify(err)}`);
    }
  }

  /* ==================== 工具 ==================== */

  /** 统一的错误处理：401 回登录页，其它错误把后端 msg 显示出来 */
  async handleError(err: Object): Promise<void> {
    if (isUnauthorized(err)) {
      // token 缺失/失效/过期：HttpUtil 已清 token，这里补一个跳转
      await gotoLogin(this.getUIContext());
      return;
    }
    this.tip = (err as Error).message;
  }

  /** 轻提示。showToast 声明了可能抛 BusinessError，包起来免得影响主流程 */
  toast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
    } catch (err) {
      console.warn(`提示显示失败: ${JSON.stringify(err)}`);
    }
  }

  avatarText(): string {
    const name: string = this.nickName.length > 0 ? this.nickName : this.userName;
    if (name.length === 0) {
      return '?';
    }
    return name.substring(0, 1).toUpperCase();
  }

  displayName(): string {
    return this.nickName.length > 0 ? this.nickName : this.userName;
  }

  /* ==================== 界面 ==================== */

  build() {
    // 外层 Stack 只为一个"底部弹层"用：点头像时从底部滑出「拍照 / 相册 / 恢复默认」
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
      // 顶部标题栏
      Row() {
        Text('我的')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
        Blank()
        if (this.loading) {
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
          // ---- 用户卡片 ----
          Column({ space: 10 }) {
            // 头像：有本地图片就显示图片，否则显示昵称首字母；点一下换头像
            Stack({ alignContent: Alignment.BottomEnd }) {
              Stack() {
                if (this.avatarPixel !== undefined) {
                  Image(this.avatarPixel)
                    .width(72)
                    .height(72)
                    .objectFit(ImageFit.Cover)
                } else {
                  Text(this.avatarText())
                    .fontSize(28)
                    .fontColor(Color.White)
                }

                if (this.avatarBusy) {
                  Stack() {
                    LoadingProgress()
                      .width(26)
                      .height(26)
                      .color(Color.White)
                  }
                  .width(72)
                  .height(72)
                  .backgroundColor('#66000000')
                }
              }
              .width(72)
              .height(72)
              .borderRadius(36)
              .backgroundColor('#0A59F7')
              .clip(true)

              if (!this.avatarBusy) {
                Text('📷')
                  .fontSize(11)
                  .width(24)
                  .height(24)
                  .borderRadius(12)
                  .backgroundColor(Color.White)
                  .textAlign(TextAlign.Center)
                  .border({ width: 1, color: '#EEEEEE' })
              }
            }
            .width(72)
            .height(72)
            .onClick(() => {
              this.openAvatarMenu().catch((err: Error) => {
                this.tip = err.message;
              });
            })

            Text(this.displayName())
              .fontSize(20)
              .fontWeight(FontWeight.Medium)

            Row({ space: 6 }) {
              Text(`账号：${this.userName}`)
                .fontSize(13)
                .fontColor('#666666')
            }

            Text('点击头像可以拍照或从相册选择')
              .fontSize(11)
              .fontColor('#BBBBBB')
          }
          .width('100%')
          .padding({ top: 22, bottom: 22 })
          .backgroundColor(Color.White)
          .borderRadius(12)

          // ---- 声纹未注册提醒 ----
          if (this.voiceprintPending) {
            Row() {
              Column({ space: 4 }) {
                Text('🎤 还没录制声纹')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#333333')
                Text('10 个数字录满才能打卡，点这里去录')
                  .fontSize(12)
                  .fontColor('#8A6D3B')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Text('去录制')
                .fontSize(13)
                .fontColor(Color.White)
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .backgroundColor('#0A59F7')
                .borderRadius(15)
            }
            .width('100%')
            .padding(16)
            .backgroundColor('#FFF8E6')
            .borderRadius(12)
            .onClick(() => {
              this.openVoiceprint().catch((err: Error) => {
                this.tip = err.message;
              });
            })
          }

          // ---- 资料 ----
          Column() {
            Row() {
              Text('声纹状态')
                .fontSize(14)
                .fontColor('#666666')
              Blank()
              Text(this.voiceprintPending ? '未注册（需要录 10 个数字）' : '已完成注册')
                .fontSize(14)
                .fontColor(this.voiceprintPending ? '#E84026' : '#37B24D')
              Text('›')
                .fontSize(18)
                .fontColor('#CCCCCC')
                .margin({ left: 4 })
            }
            .width('100%')
            .height(46)
            .onClick(() => {
              this.openVoiceprint().catch((err: Error) => {
                this.tip = err.message;
              });
            })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .backgroundColor(Color.White)
          .borderRadius(12)

          // ---- 修改昵称（默认收起，点这一行才展开输入框）----
          Column({ space: 10 }) {
            Row() {
              Text('修改昵称')
                .fontSize(15)
                .fontColor('#333333')
              Blank()
              Text(this.nickPanelOpen ? '收起' : '去修改')
                .fontSize(13)
                .fontColor('#0A59F7')
            }
            .width('100%')
            .height(28)
            .onClick(() => {
              this.nickPanelOpen = !this.nickPanelOpen;
            })

            if (this.nickPanelOpen) {
              Row({ space: 8 }) {
                TextInput({ placeholder: '新昵称（最长 32 位）', text: this.nickInput })
                  .layoutWeight(1)
                  .height(44)
                  .maxLength(32)
                  .onChange((value: string) => {
                    this.nickInput = value;
                  })
                Button('保存')
                  .height(44)
                  .fontSize(14)
                  .enabled(!this.loading)
                  .onClick(() => {
                    this.doSaveNickName().catch((err: Error) => {
                      this.tip = err.message;
                    });
                  })
              }
              .width('100%')
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(12)

          // ---- 修改密码（默认收起，点标题展开）----
          Column({ space: 10 }) {
            Row() {
              Text('修改密码')
                .fontSize(15)
                .fontColor('#333333')
              Blank()
              Text(this.pwdPanelOpen ? '收起' : '展开')
                .fontSize(13)
                .fontColor('#0A59F7')
            }
            .width('100%')
            .height(28)
            .onClick(() => {
              this.pwdPanelOpen = !this.pwdPanelOpen;
            })

            if (this.pwdPanelOpen) {
              TextInput({ placeholder: '原密码（6~32 位）', text: this.oldPassword })
                .height(44)
                .maxLength(32)
                .type(InputType.Password)
                .onChange((value: string) => {
                  this.oldPassword = value;
                })

              TextInput({ placeholder: '新密码（6~32 位）', text: this.newPassword })
                .height(44)
                .maxLength(32)
                .type(InputType.Password)
                .onChange((value: string) => {
                  this.newPassword = value;
                })

              TextInput({ placeholder: '确认新密码', text: this.confirmPassword })
                .height(44)
                .maxLength(32)
                .type(InputType.Password)
                .onChange((value: string) => {
                  this.confirmPassword = value;
                })

              Button('确认修改')
                .width('100%')
                .height(44)
                .enabled(!this.loading)
                .onClick(() => {
                  this.doChangePassword().catch((err: Error) => {
                    this.tip = err.message;
                  });
                })

              Text('修改成功后所有登录状态会失效，需要用新密码重新登录')
                .fontSize(11)
                .fontColor('#999999')
                .width('100%')
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(12)

          // ---- 退出登录 ----
          Button(this.loading ? '请稍候...' : '退出登录')
            .width('100%')
            .height(46)
            .fontSize(15)
            .backgroundColor(Color.White)
            .fontColor('#E84026')
            .enabled(!this.loading)
            .onClick(() => {
              this.doLogout().catch((err: Error) => {
                this.tip = err.message;
              });
            })

          // ---- 错误提示 ----
          if (this.tip.length > 0) {
            Text(this.tip)
              .fontSize(13)
              .fontColor('#E84026')
              .width('100%')
              .textAlign(TextAlign.Center)
          }

          Text(`接口地址：${DEFAULT_BASE_URL}`)
            .fontSize(11)
            .fontColor('#BBBBBB')
            .margin({ top: 8, bottom: 16 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)

      // 底部四个标签：考勤 / 我的 / 人员管理 / 考勤管理（后两个仅管理员）
      BottomTabs({ current: 'profile' })
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F1F3F5')

      // ---- 换头像底部弹层 ----
      if (this.avatarSheet) {
        // 半透明遮罩，点空白处关掉
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => {
            this.avatarSheet = false;
          })

        Column({ space: 8 }) {
          Text('更换头像')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor('#333333')
            .margin({ bottom: 6 })

          Button('拍照')
            .width('100%')
            .height(44)
            .fontSize(15)
            .backgroundColor('#0A59F7')
            .fontColor(Color.White)
            .onClick(() => {
              this.avatarSheet = false;
              this.pickFromCamera().catch((err: Error) => {
                this.tip = err.message;
              });
            })

          Button('从相册选择')
            .width('100%')
            .height(44)
            .fontSize(15)
            .backgroundColor('#E8F0FF')
            .fontColor('#0A59F7')
            .onClick(() => {
              this.avatarSheet = false;
              this.pickFromAlbum().catch((err: Error) => {
                this.tip = err.message;
              });
            })

          if (this.avatarPixel !== undefined) {
            Button('恢复默认头像')
              .width('100%')
              .height(44)
              .fontSize(15)
              .backgroundColor('#FFF1F0')
              .fontColor('#E84026')
              .onClick(() => {
                this.avatarSheet = false;
                this.removeAvatar().catch((err: Error) => {
                  this.tip = err.message;
                });
              })
          }

          Button('取消')
            .width('100%')
            .height(44)
            .fontSize(15)
            .backgroundColor('#F0F2F5')
            .fontColor('#666666')
            .onClick(() => {
              this.avatarSheet = false;
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 24 })
        .backgroundColor(Color.White)
        .borderRadius({ topLeft: 16, topRight: 16 })
      }
    }
    .width('100%')
    .height('100%')
  }
}
