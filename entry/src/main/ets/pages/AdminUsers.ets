import {
  AdminResetPasswordRequest,
  CreateUserRequest,
  UserListItem,
  UserPage,
  UserPageQuery,
  adminResetPassword,
  createUser,
  freezeUser,
  pageUsers,
  restoreUser
} from '../api/UserLogin';
import { resetVoiceprint } from '../api/Voiceprint';
import { BottomTabs } from '../components/BottomTabs';
import { ROLE_ADMIN, ROLE_USER, getUserId, gotoLogin, isAdmin, roleText } from '../utils/AuthStore';
import { isUnauthorized } from '../utils/HttpUtil';

/**
 * 人员管理（仅管理员，对应联调文档第 6 节）。
 *
 *   POST   /user                                             创建账号
 *   GET    /user/page?userName=&deleted=&pageNum=&pageSize=   分页查询
 *   DELETE /user/{userId}                                     冻结（逻辑删除 deleted 0→1）
 *   PUT    /user/{userId}/restore                             恢复（deleted 1→0）
 *   PUT    /user/password/{userId}                            重置密码
 *   POST   /voiceprint/reset/{userId}                          重置声纹（对方要重录 10 个数字）
 *
 * 几条文档里写明的业务规则，界面上都跟着做了：
 *   - 不能冻结自己（后端 400 "不能冻结自己"），所以本人那行的冻结按钮直接禁用
 *   - 冻结/恢复/重置密码都是幂等的，重复点不会报错
 *   - 冻结、恢复、重置密码都会让对方 token 立即失效，对方需要重新登录
 *   - 普通用户进来会被后端 403 拦住，这里也提前提示一句
 *   - 新建账号用户名不能重复（已冻结的也算重复，后端 409），创建后不会自动登录
 */
@Entry
@ComponentV2
struct AdminUsers {
  @Local list: UserListItem[] = [];
  @Local keyword: string = '';
  /** -1 全部，0 正常，1 已冻结 */
  @Local filter: number = -1;
  @Local pageNum: number = 1;
  @Local pageSize: number = 10;
  @Local total: number = 0;
  @Local pages: number = 0;
  @Local loading: boolean = false;
  @Local tip: string = '';
  @Local myUserId: number = 0;

  /** 二次确认面板：'' 关闭，'freeze' / 'restore' / 'reset' / 'create' */
  @Local pendingAction: string = '';
  @Local pendingUserId: number = 0;
  @Local pendingName: string = '';
  @Local newPassword: string = '';

  /** 新建账号表单（和重置密码的输入框分开，避免互相串值） */
  @Local createUserName: string = '';
  @Local createPassword: string = '';
  @Local createNickName: string = '';
  /** 'USER' / 'ADMIN' */
  @Local createRole: string = 'USER';
  /** 面板里的错误提示（页面底部的 tip 被遮罩挡住了，看不见） */
  @Local panelTip: string = '';

  aboutToAppear(): void {
    this.myUserId = getUserId();
    if (!isAdmin()) {
      this.tip = '没有访问权限：当前账号不是管理员';
      return;
    }
    this.load();
  }

  /* ==================== 数据 ==================== */

  async load(): Promise<void> {
    if (!isAdmin()) {
      return;
    }
    // 上一页按钮在首页时禁用，这里再兜一次，避免发无意义请求
    if (this.loading) {
      return;
    }

    this.loading = true;
    this.tip = '';

    const query: UserPageQuery = { pageNum: this.pageNum, pageSize: this.pageSize };
    const kw: string = this.keyword.trim();
    if (kw.length > 0) {
      query.userName = kw;
    }
    if (this.filter >= 0) {
      // 不传 deleted = 正常 + 已冻结都返回（文档 6.1）
      query.deleted = this.filter;
    }

    try {
      const page: UserPage = await pageUsers(query);
      this.list = page.records;
      this.total = page.total;
      this.pages = page.pages;
      this.pageNum = page.pageNum;
      this.loading = false;
    } catch (err) {
      this.loading = false;
      await this.handleError(err);
    }
  }

  /* ==================== 操作 ==================== */

  async confirm(): Promise<void> {
    const action: string = this.pendingAction;
    const userId: number = this.pendingUserId;
    if (action === 'freeze') {
      await this.doFreeze(userId);
    } else if (action === 'restore') {
      await this.doRestore(userId);
    } else if (action === 'reset') {
      await this.doReset(userId);
    } else if (action === 'voiceprint') {
      await this.doResetVoiceprint(userId);
    } else if (action === 'create') {
      await this.doCreate();
    }
  }

  /**
   * 重置声纹（文档 5 节 POST /voiceprint/reset/{userId}）。
   *
   * 用户 token 不失效，所以不用踢回登录页；但对方要重新录满 10 个数字才能打卡，
   * 而且重置前录过的音频不能再用（数据库留着模板哈希）。
   */
  async doResetVoiceprint(userId: number): Promise<void> {
    this.loading = true;
    try {
      await resetVoiceprint(userId);
    } catch (err) {
      this.loading = false;
      this.closePanel();
      await this.handleError(err);
      return;
    }
    this.loading = false;
    this.closePanel();
    this.toast('已重置该用户的声纹，对方需要重新录 10 个数字');
    await this.load();
  }

  async doFreeze(userId: number): Promise<void> {
    this.loading = true;
    try {
      await freezeUser(userId);
    } catch (err) {
      this.loading = false;
      this.closePanel();
      await this.handleError(err);
      return;
    }
    this.loading = false;
    this.closePanel();
    // 先本地改掉这一行，界面立刻变成"已冻结"；再用服务端数据校正总数和分页
    this.patchDeleted(userId, 1);
    this.toast('已冻结该用户，对方需要重新登录');
    await this.load();
  }

  async doRestore(userId: number): Promise<void> {
    this.loading = true;
    try {
      await restoreUser(userId);
    } catch (err) {
      this.loading = false;
      this.closePanel();
      await this.handleError(err);
      return;
    }
    this.loading = false;
    this.closePanel();
    this.patchDeleted(userId, 0);
    this.toast('已恢复该用户');
    await this.load();
  }

  async doReset(userId: number): Promise<void> {
    const pwd: string = this.newPassword;
    if (pwd.length < 6 || pwd.length > 32) {
      this.panelTip = '新密码长度必须在 6 到 32 个字符之间';
      return;
    }

    this.loading = true;
    this.panelTip = '';
    try {
      const params: AdminResetPasswordRequest = { newPassword: pwd };
      await adminResetPassword(userId, params);
    } catch (err) {
      this.loading = false;
      if (isUnauthorized(err)) {
        this.closePanel();
        await gotoLogin(this.getUIContext());
        return;
      }
      this.panelTip = (err as Error).message;
      return;
    }

    this.loading = false;
    this.closePanel();

    if (userId === this.myUserId) {
      // 管理员重置了自己的密码 → 自己的 token 也失效了，直接回登录页
      this.toast('已重置自己的密码，请重新登录');
      await gotoLogin(this.getUIContext());
      return;
    }
    this.toast('密码已重置，对方原有的登录状态已失效');
    await this.load();
  }

  /**
   * 创建账号（文档 6.5）。
   *
   * 前端先按文档校验一遍（用户名非空 ≤32、密码 6~32），少跑一次网络；
   * 用户名重复交给后端判断（409），msg 直接展示：
   *   "用户名已存在" / "用户名已存在且已被冻结，请先恢复账号或换一个用户名"
   */
  async doCreate(): Promise<void> {
    if (this.loading) {
      return;
    }
    const name: string = this.createUserName.trim();
    if (name.length === 0) {
      this.panelTip = '用户名不能为空';
      return;
    }
    if (name.length > 32) {
      this.panelTip = '用户名长度不能超过 32 个字符';
      return;
    }
    if (this.createPassword.length < 6 || this.createPassword.length > 32) {
      this.panelTip = '密码长度必须在 6 到 32 个字符之间';
      return;
    }
    const nick: string = this.createNickName.trim();
    if (nick.length > 32) {
      this.panelTip = '昵称长度不能超过 32 个字符';
      return;
    }

    this.loading = true;
    this.panelTip = '';
    try {
      // nickName 留空就不传，后端会自动用"新用户"
      const params: CreateUserRequest = {
        userName: name,
        password: this.createPassword,
        role: this.createRole
      };
      if (nick.length > 0) {
        params.nickName = nick;
      }
      await createUser(params);
    } catch (err) {
      this.loading = false;
      if (isUnauthorized(err)) {
        this.closePanel();
        await gotoLogin(this.getUIContext());
        return;
      }
      // 409 用户名重复、400 参数不合法：留在面板里改，不要把已填的内容丢掉
      this.panelTip = (err as Error).message;
      return;
    }

    this.loading = false;
    this.closePanel();
    this.toast(`账号「${name}」创建成功，请把初始密码告诉对方`);
    // 回到第一页重新查，保证新账号一定能看到
    this.pageNum = 1;
    await this.load();
  }

  /* ==================== 查询条件 ==================== */

  doSearch(): void {
    this.pageNum = 1;
    this.load();
  }

  resetSearch(): void {
    this.keyword = '';
    this.filter = -1;
    this.pageNum = 1;
    this.load();
  }

  setFilter(value: number): void {
    if (this.filter === value) {
      return;
    }
    this.filter = value;
    this.pageNum = 1;
    this.load();
  }

  prevPage(): void {
    if (this.pageNum <= 1 || this.loading) {
      return;
    }
    this.pageNum = this.pageNum - 1;
    this.load();
  }

  nextPage(): void {
    if (this.pageNum >= this.pages || this.loading) {
      return;
    }
    this.pageNum = this.pageNum + 1;
    this.load();
  }

  /* ==================== 面板 ==================== */

  openPanel(action: string, item: UserListItem): void {
    this.pendingAction = action;
    this.pendingUserId = item.id;
    this.pendingName = item.nickName.length > 0 ? item.nickName : item.userName;
    this.newPassword = '';
    this.panelTip = '';
    this.tip = '';
  }

  /** 打开"新建账号"面板（没有具体用户，所以单开一个方法） */
  openCreate(): void {
    this.pendingAction = 'create';
    this.pendingUserId = 0;
    this.pendingName = '';
    this.newPassword = '';
    this.createUserName = '';
    this.createPassword = '';
    this.createNickName = '';
    this.createRole = ROLE_USER;
    this.panelTip = '';
    this.tip = '';
  }

  closePanel(): void {
    this.pendingAction = '';
    this.pendingUserId = 0;
    this.pendingName = '';
    this.newPassword = '';
    this.createUserName = '';
    this.createPassword = '';
    this.createNickName = '';
    this.createRole = ROLE_USER;
    this.panelTip = '';
  }

  panelTitle(): string {
    if (this.pendingAction === 'freeze') {
      return '冻结用户';
    }
    if (this.pendingAction === 'restore') {
      return '恢复用户';
    }
    if (this.pendingAction === 'reset') {
      return '重置密码';
    }
    if (this.pendingAction === 'voiceprint') {
      return '重置声纹';
    }
    if (this.pendingAction === 'create') {
      return '新建账号';
    }
    return '';
  }

  panelMessage(): string {
    if (this.pendingAction === 'freeze') {
      return `冻结后「${this.pendingName}」将无法登录，已登录的会话会立即失效。`;
    }
    if (this.pendingAction === 'restore') {
      return `恢复后「${this.pendingName}」可以重新登录，需要重新输入密码。`;
    }
    if (this.pendingAction === 'reset') {
      return `为「${this.pendingName}」设置一个新密码，设置成功后该用户所有登录状态立即失效。`;
    }
    if (this.pendingAction === 'voiceprint') {
      return `重置后「${this.pendingName}」的 10 个数字要全部重录，之前录过的音频也不能再用。` +
        `对方的登录状态不受影响，只是暂时不能打卡。`;
    }
    if (this.pendingAction === 'create') {
      return '新账号首次登录后要先录满 10 个声纹数字，才能看自己的考勤任务。';
    }
    return '';
  }

  panelConfirmText(): string {
    if (this.pendingAction === 'restore') {
      return '恢复';
    }
    if (this.pendingAction === 'reset') {
      return '确定重置';
    }
    if (this.pendingAction === 'voiceprint') {
      return '确定重置';
    }
    if (this.pendingAction === 'create') {
      return '创建';
    }
    return '确定冻结';
  }

  /* ==================== 工具 ==================== */

  async handleError(err: Object): Promise<void> {
    if (isUnauthorized(err)) {
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

  displayName(item: UserListItem): string {
    return item.nickName.length > 0 ? item.nickName : item.userName;
  }

  /**
   * 本地先把某一行的 deleted 改掉，让界面立刻有反馈，不用等第二次请求回来。
   *
   * 注意不能写 this.list[i].deleted = 1 —— 数组元素是普通对象，改字段不会触发刷新；
   * 必须整体重建一个新数组（新对象），@Local 才能观察到。
   */
  patchDeleted(userId: number, deleted: number): void {
    if (this.filter >= 0 && this.filter !== deleted) {
      // 当前筛选条件会把这一行过滤掉，交给 load() 重新查更准确
      return;
    }
    const next: UserListItem[] = [];
    for (let i = 0; i < this.list.length; i++) {
      const it: UserListItem = this.list[i];
      const row: UserListItem = {
        id: it.id,
        userName: it.userName,
        nickName: it.nickName,
        role: it.role,
        deleted: it.id === userId ? deleted : it.deleted
      };
      next.push(row);
    }
    this.list = next;
  }

  /* ==================== 界面 ==================== */

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        // ---- 顶部栏（底部标签切页，不再需要返回箭头）----
        Row({ space: 4 }) {
          Text('人员管理')
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
          Blank()
          Text('＋ 新建')
            .fontSize(13)
            .fontColor(Color.White)
            .backgroundColor('#0A59F7')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .onClick(() => {
              this.openCreate();
            })
          Text(`共 ${this.total} 人`)
            .fontSize(13)
            .fontColor('#999999')
            .margin({ left: 8 })
        }
        .width('100%')
        .height(56)
        .padding({ left: 16, right: 16 })
        .backgroundColor(Color.White)

        // ---- 搜索 ----
        Row({ space: 8 }) {
          TextInput({ placeholder: '按用户名模糊搜索', text: this.keyword })
            .layoutWeight(1)
            .height(42)
            .maxLength(32)
            .onChange((value: string) => {
              this.keyword = value;
            })
          Button('搜索')
            .height(42)
            .fontSize(14)
            .enabled(!this.loading)
            .onClick(() => {
              this.doSearch();
            })
          Button('重置')
            .height(42)
            .fontSize(14)
            .backgroundColor('#F0F0F0')
            .fontColor('#333333')
            .enabled(!this.loading)
            .onClick(() => {
              this.resetSearch();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 8 })

        // ---- 状态筛选 ----
        Row({ space: 8 }) {
          Text('全部')
            .fontSize(13)
            .fontColor(this.filter === -1 ? Color.White : '#666666')
            .backgroundColor(this.filter === -1 ? '#0A59F7' : '#E8EAED')
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .borderRadius(14)
            .onClick(() => {
              this.setFilter(-1);
            })
          Text('正常')
            .fontSize(13)
            .fontColor(this.filter === 0 ? Color.White : '#666666')
            .backgroundColor(this.filter === 0 ? '#0A59F7' : '#E8EAED')
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .borderRadius(14)
            .onClick(() => {
              this.setFilter(0);
            })
          Text('已冻结')
            .fontSize(13)
            .fontColor(this.filter === 1 ? Color.White : '#666666')
            .backgroundColor(this.filter === 1 ? '#0A59F7' : '#E8EAED')
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .borderRadius(14)
            .onClick(() => {
              this.setFilter(1);
            })
          Blank()
          if (this.loading) {
            LoadingProgress()
              .width(18)
              .height(18)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })

        // ---- 用户列表 ----
        if (this.list.length === 0) {
          Column() {
            Text(this.loading ? '加载中...' : '没有查到用户')
              .fontSize(14)
              .fontColor('#999999')
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 10 }) {
            ForEach(this.list, (item: UserListItem) => {
              ListItem() {
                Column({ space: 10 }) {
                  Row({ space: 8 }) {
                    Text(this.displayName(item))
                      .fontSize(16)
                      .fontColor('#222222')
                    Text(roleText(item.role))
                      .fontSize(11)
                      .fontColor(item.role === ROLE_ADMIN ? '#0A59F7' : '#666666')
                      .backgroundColor(item.role === ROLE_ADMIN ? '#E8F0FF' : '#F0F0F0')
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      .borderRadius(4)
                    if (item.id === this.myUserId) {
                      Text('本人')
                        .fontSize(11)
                        .fontColor('#FF8800')
                        .backgroundColor('#FFF3E0')
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                        .borderRadius(4)
                    }
                    Blank()
                    Text(item.deleted === 1 ? '已冻结' : '正常')
                      .fontSize(12)
                      .fontColor(item.deleted === 1 ? '#E84026' : '#37B24D')
                  }
                  .width('100%')

                  Row({ space: 12 }) {
                    Text(`账号：${item.userName}`)
                      .fontSize(12)
                      .fontColor('#999999')
                    Text(`ID：${item.id}`)
                      .fontSize(12)
                      .fontColor('#999999')
                    Blank()
                  }
                  .width('100%')

                  Row({ space: 8 }) {
                    Blank()
                    Button('重置密码')
                      .height(32)
                      .fontSize(12)
                      .backgroundColor('#F0F0F0')
                      .fontColor('#333333')
                      .enabled(!this.loading)
                      .onClick(() => {
                        this.openPanel('reset', item);
                      })
                    Button('重置声纹')
                      .height(32)
                      .fontSize(12)
                      .backgroundColor('#F0F0F0')
                      .fontColor('#333333')
                      .enabled(!this.loading)
                      .onClick(() => {
                        this.openPanel('voiceprint', item);
                      })
                    if (item.deleted === 1) {
                      Button('恢复')
                        .height(32)
                        .fontSize(12)
                        .enabled(!this.loading)
                        .onClick(() => {
                          this.openPanel('restore', item);
                        })
                    } else {
                      Button('冻结')
                        .height(32)
                        .fontSize(12)
                        .backgroundColor(item.id === this.myUserId ? '#F0F0F0' : '#E84026')
                        .fontColor(item.id === this.myUserId ? '#999999' : Color.White)
                        .enabled(item.id !== this.myUserId && !this.loading)
                        .onClick(() => {
                          this.openPanel('freeze', item);
                        })
                    }
                  }
                  .width('100%')
                }
                .width('100%')
                .padding(14)
                .backgroundColor(Color.White)
                .borderRadius(12)
              }
              // 键值必须包含"会变化的状态"，否则 ForEach 认为还是同一项，
              // 直接复用旧组件、不重新渲染 —— 冻结后界面还显示"正常"就是这个坑。
            }, (item: UserListItem) => `${item.id}_${item.deleted}_${item.role}_${item.nickName}`)
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 16, right: 16 })
          .scrollBar(BarState.Off)
        }

        // ---- 错误提示 ----
        if (this.tip.length > 0) {
          Text(this.tip)
            .fontSize(13)
            .fontColor('#E84026')
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ left: 16, right: 16, top: 6, bottom: 6 })
        }

        // ---- 分页 ----
        Row({ space: 12 }) {
          Button('上一页')
            .height(36)
            .fontSize(13)
            .backgroundColor('#F0F0F0')
            .fontColor('#333333')
            .enabled(this.pageNum > 1 && !this.loading)
            .onClick(() => {
              this.prevPage();
            })
          Text(`${this.pageNum} / ${this.pages <= 0 ? 1 : this.pages}`)
            .fontSize(13)
            .fontColor('#666666')
          Button('下一页')
            .height(36)
            .fontSize(13)
            .backgroundColor('#F0F0F0')
            .fontColor('#333333')
            .enabled(this.pageNum < this.pages && !this.loading)
            .onClick(() => {
              this.nextPage();
            })
        }
        .width('100%')
        .height(52)
        .justifyContent(FlexAlign.Center)

        // 底部标签：考勤 / 我的 / 人员管理 / 考勤管理
        BottomTabs({ current: 'users' })
      }
      .width('100%')
      .height('100%')

      // ---- 二次确认面板 ----
      if (this.pendingAction.length > 0) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => {
            this.closePanel();
          })

        Column({ space: 14 }) {
          Text(this.panelTitle())
            .fontSize(17)
            .fontWeight(FontWeight.Medium)

          if (this.pendingAction === 'create') {
            TextInput({ placeholder: '用户名（最长 32 位，不能重复）', text: this.createUserName })
              .height(44)
              .maxLength(32)
              .onChange((value: string) => {
                this.createUserName = value;
              })

            TextInput({ placeholder: '初始密码（6~32 位）', text: this.createPassword })
              .height(44)
              .maxLength(32)
              .type(InputType.Password)
              .onChange((value: string) => {
                this.createPassword = value;
              })

            TextInput({ placeholder: '昵称（可选，留空默认"新用户"）', text: this.createNickName })
              .height(44)
              .maxLength(32)
              .onChange((value: string) => {
                this.createNickName = value;
              })

            Row({ space: 8 }) {
              Text('角色')
                .fontSize(13)
                .fontColor('#666666')
              Text('普通用户')
                .fontSize(13)
                .fontColor(this.createRole === ROLE_USER ? Color.White : '#666666')
                .backgroundColor(this.createRole === ROLE_USER ? '#0A59F7' : '#E8EAED')
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .borderRadius(14)
                .onClick(() => {
                  this.createRole = ROLE_USER;
                })
              Text('管理员')
                .fontSize(13)
                .fontColor(this.createRole === ROLE_ADMIN ? Color.White : '#666666')
                .backgroundColor(this.createRole === ROLE_ADMIN ? '#0A59F7' : '#E8EAED')
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .borderRadius(14)
                .onClick(() => {
                  this.createRole = ROLE_ADMIN;
                })
              Blank()
            }
            .width('100%')
          }

          Text(this.panelMessage())
            .fontSize(13)
            .fontColor('#666666')
            .width('100%')
            .textAlign(TextAlign.Center)

          if (this.panelTip.length > 0) {
            Text(this.panelTip)
              .fontSize(12)
              .fontColor('#E84026')
              .width('100%')
              .textAlign(TextAlign.Center)
          }

          if (this.pendingAction === 'reset') {
            TextInput({ placeholder: '新密码（6~32 位）', text: this.newPassword })
              .height(44)
              .maxLength(32)
              .type(InputType.Password)
              .onChange((value: string) => {
                this.newPassword = value;
              })
          }

          Row({ space: 12 }) {
            Button('取消')
              .layoutWeight(1)
              .height(42)
              .backgroundColor('#F0F0F0')
              .fontColor('#333333')
              .onClick(() => {
                this.closePanel();
              })
            Button(this.panelConfirmText())
              .layoutWeight(1)
              .height(42)
              .enabled(!this.loading)
              .onClick(() => {
                this.confirm().catch((err: Error) => {
                  this.panelTip = err.message;
                });
              })
          }
          .width('100%')
        }
        .width('84%')
        .padding(20)
        .backgroundColor(Color.White)
        .borderRadius(16)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F1F3F5')
  }
}
