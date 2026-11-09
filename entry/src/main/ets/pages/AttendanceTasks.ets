import { common } from '@kit.AbilityKit';
import {
  AttendanceTaskDetail,
  AttendanceTaskListItem,
  AttendanceTaskPage,
  AttendanceTaskPageQuery,
  AttendanceTaskParticipant,
  CHECK_TYPE_IN,
  CHECK_TYPE_OUT,
  CreateAttendanceTaskRequest,
  CreateAttendanceTaskResult,
  ManualRecordRequest,
  ManualRecordResult,
  STATE_CLOSED,
  STATE_OPEN,
  STATE_UPCOMING,
  UpdateManualRecordRequest,
  checkTypeText,
  createAttendanceTask,
  createManualRecord,
  formatTaskTime,
  getAttendanceTaskDetail,
  nowText,
  pageAttendanceTasks,
  parseDateTimeText,
  partsToMillis,
  revokeManualRecord,
  stateText,
  toIsoWithOffset,
  updateManualRecord
} from '../api/Attendance';
import { UserListItem, UserPage, pageUsers } from '../api/UserLogin';
import { ROLE_ADMIN, gotoLogin, isAdmin } from '../utils/AuthStore';
import { BottomTabs } from '../components/BottomTabs';
import { isUnauthorized } from '../utils/HttpUtil';
import { GeoPlace, GeoPoint, ensureLocationPermission, geocodeAddress, getCurrentGeoPoint, isValidCoordinate, reverseGeocode } from '../utils/Location';

/** 打卡点半径默认 200 米，后端允许 50~1000 */
const DEFAULT_RADIUS_M: number = 200;
/** 详情里补卡时定位超时 */
const LOCATE_TIMEOUT_MS: number = 8000;

/**
 * 考勤任务管理（仅管理员，对应《前后端联调文档-考勤任务模块.md》3~5 节）。
 *
 *   POST /attendance/task             新建任务（IN/OUT + 时间窗口 + 人员名单）
 *   GET  /attendance/task/page        分页查询，可按 state / checkType 过滤
 *   GET  /attendance/task/{taskId}    查看详情和名单完成情况
 *
 * 文档第 10 节强调的几条，界面上也跟着做了：
 *   - 任务创建后不能改、不能取消、不能删除，所以按钮文案是"创建"，创建前会二次确认信息
 *   - 任务过了 endAt 自动变 CLOSED，state 完全由后端给，前端不自己算
 *   - 同一个用户可以同时出现在多个任务里，后端不校验，前端也不拦
 *   - 可以指定还没录声纹的人，等他录完才能打卡
 */
@Entry
@ComponentV2
struct AttendanceTasks {
  @Local list: AttendanceTaskListItem[] = [];
  @Local pageNum: number = 1;
  @Local pageSize: number = 10;
  @Local total: number = 0;
  @Local pages: number = 0;
  @Local loading: boolean = false;
  @Local tip: string = '';
  /** '' 全部，或 UPCOMING / OPEN / CLOSED */
  @Local stateFilter: string = '';
  /** '' 全部，或 IN / OUT */
  @Local typeFilter: string = '';

  /* ---- 新建任务 ---- */
  @Local createOpen: boolean = false;
  @Local formTitle: string = '';
  @Local formCheckType: string = 'IN';
  @Local startInput: string = '';
  @Local endInput: string = '';
  @Local users: UserListItem[] = [];
  @Local usersTotal: number = 0;
  @Local usersLoading: boolean = false;
  @Local selectedIds: number[] = [];
  /** 面板里的错误提示（不能复用页面底部的 tip，被遮罩挡住了看不见） */
  @Local panelTip: string = '';
  /* ---- 新建任务：可选打卡点（文档 3.2，全部可选） ---- */
  @Local formAddress: string = '';
  @Local formLatitude: string = '';
  @Local formLongitude: string = '';
  @Local formRadius: string = '200';
  @Local formLocating: boolean = false;
  /** 地址搜索关键词 */
  @Local addressQuery: string = '';
  /** 搜索结果（点一个就填进表单） */
  @Local addressResults: GeoPlace[] = [];
  @Local addressSearching: boolean = false;

  /* ---- 任务详情 ---- */
  @Local detailOpen: boolean = false;
  @Local detailLoading: boolean = false;
  @Local dTitle: string = '';
  @Local dCheckType: string = '';
  @Local dState: string = '';
  @Local dStartAt: string = '';
  @Local dEndAt: string = '';
  @Local dAddress: string = '';
  @Local dRadiusM: number | null = null;
  @Local dLatitude: number | null = null;
  @Local dLongitude: number | null = null;
  @Local dTaskId: number = 0;
  @Local participants: AttendanceTaskParticipant[] = [];

  /* ---- 补卡 / 修改补卡面板 ---- */
  @Local manualOpen: boolean = false;
  @Local manualTip: string = '';
  @Local manualSaving: boolean = false;
  /** true = 新建补卡，false = 修改已有的补卡 */
  @Local manualCreate: boolean = true;
  /** 撤销确认框 */
  @Local revokeOpen: boolean = false;
  @Local manualUserId: number = 0;
  @Local manualUserText: string = '';
  @Local manualRecordId: number = 0;
  @Local manualCheckAt: string = '';
  @Local manualRemark: string = '';
  @Local manualCheckingIn: boolean = false;

  aboutToAppear(): void {
    if (!isAdmin()) {
      this.tip = '没有访问权限：当前账号不是管理员';
      return;
    }
    this.load();
  }

  /* ==================== 数据 ==================== */

  async load(): Promise<void> {
    if (!isAdmin() || this.loading) {
      return;
    }
    this.loading = true;
    this.tip = '';

    const query: AttendanceTaskPageQuery = { pageNum: this.pageNum, pageSize: this.pageSize };
    if (this.stateFilter.length > 0) {
      query.state = this.stateFilter;
    }
    if (this.typeFilter.length > 0) {
      query.checkType = this.typeFilter;
    }

    try {
      const page: AttendanceTaskPage = await pageAttendanceTasks(query);
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

  /** 打开新建面板：时间先填好"今天 08:00 ~ 09:30"，人员列表懒加载一次 */
  openCreate(): void {
    this.formTitle = '';
    this.formCheckType = CHECK_TYPE_IN;
    this.startInput = nowText(8, 0);
    this.endInput = nowText(9, 30);
    this.selectedIds = [];
    this.panelTip = '';
    // 打卡点默认不填 = 不限位置；要限位置就搜地址或点"用当前位置"
    this.formAddress = '';
    this.formLatitude = '';
    this.formLongitude = '';
    this.formRadius = `${DEFAULT_RADIUS_M}`;
    this.formLocating = false;
    this.addressQuery = '';
    this.addressResults = [];
    this.addressSearching = false;
    this.createOpen = true;
    if (this.users.length === 0) {
      this.loadUsers();
    }
  }

  closeCreate(): void {
    this.createOpen = false;
    this.panelTip = '';
  }

  /**
   * 拉可选人员：只看正常账号（deleted=0），冻结的人后端会拒绝。
   * 文档说一次最多 500 人，这里先取前 100 个（页大小上限的合理值）。
   */
  async loadUsers(): Promise<void> {
    if (this.usersLoading) {
      return;
    }
    this.usersLoading = true;
    try {
      const page: UserPage = await pageUsers({ pageNum: 1, pageSize: 100, deleted: 0 });
      this.users = page.records;
      this.usersTotal = page.total;
      this.usersLoading = false;
    } catch (err) {
      this.usersLoading = false;
      if (isUnauthorized(err)) {
        await gotoLogin(this.getUIContext());
        return;
      }
      this.panelTip = `人员加载失败：${(err as Error).message}`;
    }
  }

  async submitCreate(): Promise<void> {
    if (this.loading) {
      return;
    }
    const title: string = this.formTitle.trim();
    if (title.length > 64) {
      this.panelTip = '任务名称不能超过 64 个字符';
      return;
    }
    if (this.selectedIds.length === 0) {
      this.panelTip = '请至少选择 1 个参与人员';
      return;
    }
    if (this.selectedIds.length > 500) {
      this.panelTip = '一次最多指定 500 人';
      return;
    }
    const start = parseDateTimeText(this.startInput);
    if (start === null) {
      this.panelTip = '开始时间格式不对，请按 2026-10-28 08:00 填写';
      return;
    }
    const end = parseDateTimeText(this.endInput);
    if (end === null) {
      this.panelTip = '结束时间格式不对，请按 2026-10-28 08:00 填写';
      return;
    }
    if (partsToMillis(end) <= partsToMillis(start)) {
      this.panelTip = '结束时间必须晚于开始时间';
      return;
    }

    // 打卡点：要么都不填（不限位置），要么经纬度都填且合法
    const latText: string = this.formLatitude.trim();
    const lngText: string = this.formLongitude.trim();
    const hasLat: boolean = latText.length > 0;
    const hasLng: boolean = lngText.length > 0;
    let latitude: number = 0;
    let longitude: number = 0;
    let radiusM: number = DEFAULT_RADIUS_M;
    if (hasLat !== hasLng) {
      this.panelTip = '纬度和经度要一起填，只填一个不行';
      return;
    }
    if (hasLat && hasLng) {
      latitude = Number.parseFloat(latText);
      longitude = Number.parseFloat(lngText);
      if (Number.isNaN(latitude) || Number.isNaN(longitude)) {
        this.panelTip = '经纬度必须是数字，例如 30.572815 / 104.066801';
        return;
      }
      if (!isValidCoordinate(latitude, longitude)) {
        this.panelTip = '经纬度超出合法范围（纬度 -90~90，经度 -180~180）';
        return;
      }
      const radiusText: string = this.formRadius.trim();
      if (radiusText.length > 0) {
        radiusM = Number.parseInt(radiusText, 10);
        if (Number.isNaN(radiusM)) {
          this.panelTip = '半径要填整数（米）';
          return;
        }
      }
      if (radiusM < 50 || radiusM > 1000) {
        this.panelTip = '打卡半径只能在 50 ~ 1000 米之间';
        return;
      }
    }

    this.loading = true;
    this.panelTip = '';
    try {
      // title 留空就不传，后端按日期 + 类型自动生成
      const params: CreateAttendanceTaskRequest = {
        checkType: this.formCheckType,
        startAt: toIsoWithOffset(start),
        endAt: toIsoWithOffset(end),
        userIds: this.selectedIds
      };
      if (title.length > 0) {
        params.title = title;
      }
      // 有打卡点才带坐标：不带就是"不限位置"，后端按不校验位置处理
      if (hasLat && hasLng) {
        params.latitude = latitude;
        params.longitude = longitude;
        params.radiusM = radiusM;
        const address: string = this.formAddress.trim();
        if (address.length > 0) {
          params.address = address;
        }
      }
      const result: CreateAttendanceTaskResult = await createAttendanceTask(params);
      this.loading = false;
      this.closeCreate();
      this.toast(`任务已创建，名单 ${result.participantCount} 人`);
      this.pageNum = 1;
      await this.load();
    } catch (err) {
      this.loading = false;
      if (isUnauthorized(err)) {
        await gotoLogin(this.getUIContext());
        return;
      }
      // 参数错误（用户被冻结等）保留面板，让管理员改完再提交
      this.panelTip = (err as Error).message;
    }
  }

  /** 打开详情：拉名单完成情况 */
  async openDetail(taskId: number): Promise<void> {
    if (this.detailLoading) {
      return;
    }
    this.detailLoading = true;
    this.detailOpen = true;
    this.panelTip = '';
    this.participants = [];
    try {
      const detail: AttendanceTaskDetail = await getAttendanceTaskDetail(taskId);
      this.dTaskId = detail.taskId;
      this.dTitle = detail.title;
      this.dCheckType = detail.checkType;
      this.dState = detail.state;
      this.dStartAt = detail.startAt;
      this.dEndAt = detail.endAt;
      this.dLatitude = detail.latitude;
      this.dLongitude = detail.longitude;
      this.dRadiusM = detail.radiusM;
      this.dAddress = detail.address !== null ? detail.address : '';
      this.participants = detail.participants;
      this.detailLoading = false;
    } catch (err) {
      this.detailLoading = false;
      this.detailOpen = false;
      await this.handleError(err);
    }
  }

  closeDetail(): void {
    this.detailOpen = false;
    this.participants = [];
  }

  /* ==================== 打卡点（新建任务用） ==================== */

  /** 把管理员当前位置填进表单，并顺手反查一下地点名（查不到就留空，不挡流程） */
  async useCurrentLocationForForm(): Promise<void> {
    if (this.formLocating) {
      return;
    }
    this.formLocating = true;
    this.panelTip = '';
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const granted: boolean = await ensureLocationPermission(context);
      if (!granted) {
        this.panelTip = '没拿到定位权限，请到系统设置里允许定位后再试';
        this.formLocating = false;
        return;
      }
      const point: GeoPoint = await getCurrentGeoPoint(LOCATE_TIMEOUT_MS);
      this.formLatitude = point.latitude.toFixed(6);
      this.formLongitude = point.longitude.toFixed(6);
      if (this.formRadius.trim().length === 0) {
        this.formRadius = `${DEFAULT_RADIUS_M}`;
      }
      // 反查地址只是为了让"地点名称"有字，失败了不影响建任务
      if (this.formAddress.trim().length === 0) {
        const address: string = await reverseGeocode(point);
        if (address.length > 0) {
          this.formAddress = address;
        }
      }
      this.formLocating = false;
    } catch (err) {
      this.formLocating = false;
      this.panelTip = (err as Error).message;
    }
  }

  /** 搜地址：管理员打「天府三街地铁站」这种关键词，不用知道经纬度 */
  async searchAddress(): Promise<void> {
    if (this.addressSearching) {
      return;
    }
    this.addressSearching = true;
    this.panelTip = '';
    this.addressResults = [];
    try {
      const places: GeoPlace[] = await geocodeAddress(this.addressQuery);
      this.addressResults = places;
      this.addressSearching = false;
    } catch (err) {
      this.addressSearching = false;
      this.panelTip = (err as Error).message;
    }
  }

  /** 选中一个搜索结果 → 纬度/经度/地点名一起填好 */
  applyPlace(place: GeoPlace): void {
    this.formAddress = place.name;
    this.formLatitude = place.latitude.toFixed(6);
    this.formLongitude = place.longitude.toFixed(6);
    if (this.formRadius.trim().length === 0) {
      this.formRadius = `${DEFAULT_RADIUS_M}`;
    }
    this.addressResults = [];
    this.addressQuery = '';
    this.panelTip = '';
  }

  clearAddressSearch(): void {
    this.addressQuery = '';
    this.addressResults = [];
  }

  clearLocationForm(): void {
    this.formAddress = '';
    this.formLatitude = '';
    this.formLongitude = '';
    this.formRadius = `${DEFAULT_RADIUS_M}`;
    this.addressQuery = '';
    this.addressResults = [];
    this.panelTip = '';
  }

  /* ==================== 补卡 / 修改 / 撤销 ==================== */

  pad2(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }

  /** 当前本地时间，格式 2026-10-29 08:05（后端按设备时区 +08:00 解析） */
  nowDateTimeText(): string {
    const now: Date = new Date();
    return `${now.getFullYear()}-${this.pad2(now.getMonth() + 1)}-${this.pad2(now.getDate())} ` +
      `${this.pad2(now.getHours())}:${this.pad2(now.getMinutes())}`;
  }

  /** 能不能补卡：没打卡的 PENDING 才能补 */
  canManualCreate(item: AttendanceTaskParticipant): boolean {
    return item.status !== 'DONE';
  }

  /** 能不能修改/撤销：只对 source=MANUAL 的记录开放，后端也会再校验一次 */
  canManualEdit(item: AttendanceTaskParticipant): boolean {
    return item.status === 'DONE' && item.source === 'MANUAL';
  }

  openManualCreate(item: AttendanceTaskParticipant): void {
    this.manualCreate = true;
    this.manualOpen = true;
    this.manualTip = '';
    this.manualUserId = item.userId;
    this.manualUserText = this.displayParticipant(item);
    this.manualRecordId = 0;
    this.manualCheckAt = this.nowDateTimeText();
    this.manualRemark = '';
  }

  openManualUpdate(item: AttendanceTaskParticipant): void {
    this.manualCreate = false;
    this.manualOpen = true;
    this.manualTip = '';
    this.manualUserId = item.userId;
    this.manualUserText = this.displayParticipant(item);
    this.manualRecordId = item.recordId !== null ? item.recordId : 0;
    // 用已有打卡时间预填，改成管理员想写的时间
    this.manualCheckAt = item.checkedAt !== null ? formatTaskTime(item.checkedAt) : this.nowDateTimeText();
    this.manualRemark = item.remark !== null ? item.remark : '';
  }

  closeManual(): void {
    this.manualOpen = false;
    this.manualTip = '';
  }

  async submitManual(): Promise<void> {
    if (this.manualSaving) {
      return;
    }
    const checkAtText: string = this.manualCheckAt.trim();
    if (checkAtText.length === 0) {
      this.manualTip = '请填打卡时间，格式 2026-10-29 08:05';
      return;
    }
    const parts = parseDateTimeText(checkAtText);
    if (parts === null) {
      this.manualTip = '时间格式不对，请按 2026-10-29 08:05 填写';
      return;
    }
    const remark: string = this.manualRemark.trim();
    if (remark.length > 128) {
      this.manualTip = '备注不能超过 128 个字符';
      return;
    }
    this.manualSaving = true;
    this.manualTip = '';
    try {
      if (this.manualCreate) {
        const params: ManualRecordRequest = {
          taskId: this.dTaskId,
          userId: this.manualUserId,
          checkAt: toIsoWithOffset(parts)
        };
        if (remark.length > 0) {
          params.remark = remark;
        }
        const result: ManualRecordResult = await createManualRecord(params);
        this.manualSaving = false;
        this.closeManual();
        this.toast(`${this.manualUserText} 已补卡（记录 ${result.recordId}）`);
      } else {
        const params: UpdateManualRecordRequest = { checkAt: toIsoWithOffset(parts) };
        // 空串 = 清空备注，后端有明确支持，所以这里传空串而不是省略
        params.remark = remark;
        await updateManualRecord(this.manualRecordId, params);
        this.manualSaving = false;
        this.closeManual();
        this.toast('补卡记录已修改');
      }
      await this.refreshDetail();
    } catch (err) {
      this.manualSaving = false;
      if (isUnauthorized(err)) {
        await gotoLogin(this.getUIContext());
        return;
      }
      this.manualTip = (err as Error).message;
    }
  }

  /** 撤销补卡：撤销后名单回到"待打卡" */
  async doRevoke(): Promise<void> {
    if (this.manualSaving) {
      return;
    }
    this.manualSaving = true;
    try {
      await revokeManualRecord(this.manualRecordId);
      const name: string = this.manualUserText;
      this.manualSaving = false;
      this.revokeOpen = false;
      this.manualOpen = false;
      this.toast(`已撤销 ${name} 的补卡`);
      await this.refreshDetail();
    } catch (err) {
      this.manualSaving = false;
      if (isUnauthorized(err)) {
        await gotoLogin(this.getUIContext());
        return;
      }
      this.manualTip = (err as Error).message;
    }
  }

  /** 补卡/撤销之后重新拉详情，名单状态跟着变 */
  async refreshDetail(): Promise<void> {
    if (this.dTaskId <= 0) {
      return;
    }
    try {
      const detail: AttendanceTaskDetail = await getAttendanceTaskDetail(this.dTaskId);
      this.dState = detail.state;
      this.participants = detail.participants;
    } catch (err) {
      if (isUnauthorized(err)) {
        await gotoLogin(this.getUIContext());
        return;
      }
      this.tip = (err as Error).message;
    }
    // 列表里的"完成 N / M 人"也要更新
    await this.load();
  }

  /** 详情里的打卡点文案 */
  detailLocationText(): string {
    if (this.dLatitude === null || this.dLongitude === null) {
      return '不限位置';
    }
    const address: string = this.dAddress.length > 0 ? this.dAddress : '打卡点';
    const radius: string = this.dRadiusM !== null ? `${this.dRadiusM} 米` : '默认半径';
    return `${address}（半径 ${radius}）`;
  }

  /* ==================== 人员选择 ==================== */

  isSelected(userId: number): boolean {
    return this.selectedIds.indexOf(userId) >= 0;
  }

  toggleUser(userId: number): void {
    const next: number[] = [];
    let found: boolean = false;
    for (let i = 0; i < this.selectedIds.length; i++) {
      if (this.selectedIds[i] === userId) {
        found = true;
      } else {
        next.push(this.selectedIds[i]);
      }
    }
    if (!found) {
      next.push(userId);
    }
    this.selectedIds = next;
    this.panelTip = '';
  }

  selectAllUsers(): void {
    const next: number[] = [];
    for (let i = 0; i < this.users.length; i++) {
      next.push(this.users[i].id);
    }
    this.selectedIds = next;
  }

  clearAllUsers(): void {
    this.selectedIds = [];
  }

  /* ==================== 筛选 / 翻页 ==================== */

  setStateFilter(value: string): void {
    if (this.stateFilter === value) {
      return;
    }
    this.stateFilter = value;
    this.pageNum = 1;
    this.load();
  }

  setTypeFilter(value: string): void {
    if (this.typeFilter === value) {
      return;
    }
    this.typeFilter = value;
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

  /* ==================== 工具 ==================== */

  async handleError(err: Object): Promise<void> {
    if (isUnauthorized(err)) {
      await gotoLogin(this.getUIContext());
      return;
    }
    // 403（非管理员）和 400/404 都只是提示，token 还是好的
    this.tip = (err as Error).message;
  }

  toast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
    } catch (err) {
      console.warn(`提示显示失败: ${JSON.stringify(err)}`);
    }
  }

  stateColor(state: string): string {
    if (state === STATE_OPEN) {
      return '#37B24D';
    }
    if (state === STATE_UPCOMING) {
      return '#0A59F7';
    }
    return '#999999';
  }

  displayUser(item: UserListItem): string {
    return item.nickName.length > 0 ? item.nickName : item.userName;
  }

  displayParticipant(item: AttendanceTaskParticipant): string {
    return item.nickName.length > 0 ? item.nickName : item.userName;
  }

  /* ==================== 界面 ==================== */

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        // ---- 顶部栏（底部标签切页，不再需要返回箭头）----
        Row({ space: 4 }) {
          Text('考勤管理')
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
        }
        .width('100%')
        .height(56)
        .padding({ left: 16, right: 16 })
        .backgroundColor(Color.White)

        // ---- 状态筛选 ----
        Row({ space: 8 }) {
          Text('全部')
            .fontSize(13)
            .fontColor(this.stateFilter.length === 0 ? Color.White : '#666666')
            .backgroundColor(this.stateFilter.length === 0 ? '#0A59F7' : '#E8EAED')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .onClick(() => {
              this.setStateFilter('');
            })
          ForEach([STATE_UPCOMING, STATE_OPEN, STATE_CLOSED], (value: string) => {
            Text(stateText(value))
              .fontSize(13)
              .fontColor(this.stateFilter === value ? Color.White : '#666666')
              .backgroundColor(this.stateFilter === value ? '#0A59F7' : '#E8EAED')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(14)
              .onClick(() => {
                this.setStateFilter(value);
              })
          }, (value: string) => `state_${value}_${this.stateFilter === value}`)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10 })

        Row({ space: 8 }) {
          Text('全部')
            .fontSize(13)
            .fontColor(this.typeFilter.length === 0 ? Color.White : '#666666')
            .backgroundColor(this.typeFilter.length === 0 ? '#0A59F7' : '#E8EAED')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .onClick(() => {
              this.setTypeFilter('');
            })
          Text('上班打卡')
            .fontSize(13)
            .fontColor(this.typeFilter === CHECK_TYPE_IN ? Color.White : '#666666')
            .backgroundColor(this.typeFilter === CHECK_TYPE_IN ? '#0A59F7' : '#E8EAED')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .onClick(() => {
              this.setTypeFilter(CHECK_TYPE_IN);
            })
          Text('下班打卡')
            .fontSize(13)
            .fontColor(this.typeFilter === CHECK_TYPE_OUT ? Color.White : '#666666')
            .backgroundColor(this.typeFilter === CHECK_TYPE_OUT ? '#0A59F7' : '#E8EAED')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .onClick(() => {
              this.setTypeFilter(CHECK_TYPE_OUT);
            })
          Blank()
          if (this.loading) {
            LoadingProgress()
              .width(18)
              .height(18)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 8 })

        // ---- 任务列表 ----
        if (this.list.length === 0) {
          Column() {
            Text(this.loading ? '加载中...' : '还没有考勤任务')
              .fontSize(14)
              .fontColor('#999999')
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 10 }) {
            ForEach(this.list, (item: AttendanceTaskListItem) => {
              ListItem() {
                Column({ space: 8 }) {
                  Row({ space: 8 }) {
                    Text(item.title)
                      .fontSize(15)
                      .fontColor('#222222')
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(checkTypeText(item.checkType))
                      .fontSize(11)
                      .fontColor('#0A59F7')
                      .backgroundColor('#E8F0FF')
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      .borderRadius(4)
                    Text(stateText(item.state))
                      .fontSize(11)
                      .fontColor(this.stateColor(item.state))
                  }
                  .width('100%')

                  Row({ space: 8 }) {
                    Text(`${formatTaskTime(item.startAt)} ~ ${formatTaskTime(item.endAt)}`)
                      .fontSize(12)
                      .fontColor('#999999')
                    Blank()
                  }
                  .width('100%')

                  Row({ space: 8 }) {
                    Text(`完成 ${item.doneCount} / ${item.participantCount} 人`)
                      .fontSize(12)
                      .fontColor('#666666')
                    Blank()
                    Text('查看名单 ›')
                      .fontSize(12)
                      .fontColor('#0A59F7')
                  }
                  .width('100%')
                }
                .width('100%')
                .padding(14)
                .backgroundColor(Color.White)
                .borderRadius(12)
                .onClick(() => {
                  this.openDetail(item.taskId).catch((err: Error) => {
                    this.tip = err.message;
                  });
                })
              }
              // 键里带上 state / doneCount，状态变了才会重新渲染
            }, (item: AttendanceTaskListItem) =>
              `${item.taskId}_${item.state}_${item.doneCount}_${item.participantCount}`)
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
          Text(`${this.pageNum} / ${this.pages <= 0 ? 1 : this.pages}    共 ${this.total} 个任务`)
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
        BottomTabs({ current: 'adminTasks' })
      }
      .width('100%')
      .height('100%')

      // ---- 新建任务面板 ----
      if (this.createOpen) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => {
            this.closeCreate();
          })

        Column() {
          Row() {
            Text('新建考勤任务')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
            Blank()
            Text('✕')
              .fontSize(16)
              .fontColor('#999999')
              .onClick(() => {
                this.closeCreate();
              })
          }
          .width('100%')
          .height(36)

          Scroll() {
            Column({ space: 10 }) {
              Text('任务名称（可选，留空自动生成"日期 + 上班/下班打卡"）')
                .fontSize(12)
                .fontColor('#999999')
                .width('100%')
              TextInput({ placeholder: '例如 2026-10-28 上班打卡', text: this.formTitle })
                .height(42)
                .maxLength(64)
                .onChange((value: string) => {
                  this.formTitle = value;
                })

              Text('打卡类型')
                .fontSize(12)
                .fontColor('#999999')
                .width('100%')
              Row({ space: 10 }) {
                Text('上班 IN')
                  .fontSize(13)
                  .fontColor(this.formCheckType === CHECK_TYPE_IN ? Color.White : '#666666')
                  .backgroundColor(this.formCheckType === CHECK_TYPE_IN ? '#0A59F7' : '#E8EAED')
                  .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                  .borderRadius(14)
                  .onClick(() => {
                    this.formCheckType = CHECK_TYPE_IN;
                  })
                Text('下班 OUT')
                  .fontSize(13)
                  .fontColor(this.formCheckType === CHECK_TYPE_OUT ? Color.White : '#666666')
                  .backgroundColor(this.formCheckType === CHECK_TYPE_OUT ? '#0A59F7' : '#E8EAED')
                  .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                  .borderRadius(14)
                  .onClick(() => {
                    this.formCheckType = CHECK_TYPE_OUT;
                  })
                Blank()
              }
              .width('100%')

              Text('允许打卡时间（格式 2026-10-28 08:00，设备时区自动带上）')
                .fontSize(12)
                .fontColor('#999999')
                .width('100%')
              TextInput({ placeholder: '开始时间', text: this.startInput })
                .height(42)
                .maxLength(16)
                .onChange((value: string) => {
                  this.startInput = value;
                })
              TextInput({ placeholder: '结束时间', text: this.endInput })
                .height(42)
                .maxLength(16)
                .onChange((value: string) => {
                  this.endInput = value;
                })

              // ---- 打卡点（可选，经纬度都留空 = 不限位置） ----
              Row({ space: 8 }) {
                Text('打卡点（可选，留空则不限位置）')
                  .fontSize(12)
                  .fontColor('#999999')
                Blank()
                if (this.formLocating) {
                  LoadingProgress()
                    .width(16)
                    .height(16)
                } else {
                  Text('用当前位置')
                    .fontSize(12)
                    .fontColor('#0A59F7')
                    .onClick(() => {
                      this.useCurrentLocationForForm().catch((err: Error) => {
                        this.panelTip = err.message;
                      });
                    })
                }
                if (this.formAddress.length > 0 || this.formLatitude.length > 0 ||
                  this.formLongitude.length > 0) {
                  Text('清除')
                    .fontSize(12)
                    .fontColor('#0A59F7')
                    .margin({ left: 8 })
                    .onClick(() => {
                      this.clearLocationForm();
                    })
                }
              }
              .width('100%')

              // 搜地址：打关键词（大厦名/地铁站/小区名）就能拿到经纬度，不用自己查
              Row({ space: 8 }) {
                TextInput({ placeholder: '搜地点，例如 天府三街地铁站 / 环球中心', text: this.addressQuery })
                  .layoutWeight(1)
                  .height(42)
                  .maxLength(64)
                  .onChange((value: string) => {
                    this.addressQuery = value;
                  })
                  .onSubmit(() => {
                    this.searchAddress().catch((err: Error) => {
                      this.panelTip = err.message;
                    });
                  })
                Button(this.addressSearching ? '搜索中' : '搜索')
                  .height(42)
                  .fontSize(13)
                  .backgroundColor('#E8F0FF')
                  .fontColor('#0A59F7')
                  .enabled(!this.addressSearching && this.addressQuery.trim().length > 0)
                  .onClick(() => {
                    this.searchAddress().catch((err: Error) => {
                      this.panelTip = err.message;
                    });
                  })
              }
              .width('100%')

              if (this.addressResults.length > 0) {
                Column({ space: 2 }) {
                  ForEach(this.addressResults, (place: GeoPlace) => {
                    Row() {
                      Text(place.name)
                        .fontSize(13)
                        .fontColor('#222222')
                        .layoutWeight(1)
                        .maxLines(2)
                      Text('选这个')
                        .fontSize(12)
                        .fontColor('#0A59F7')
                    }
                    .width('100%')
                    .padding({ top: 8, bottom: 8 })
                    .onClick(() => {
                      this.applyPlace(place);
                    })
                  }, (place: GeoPlace) => `${place.name}_${place.latitude}_${place.longitude}`)
                }
                .width('100%')
                .padding({ left: 10, right: 10 })
                .backgroundColor('#F7F8FA')
                .borderRadius(8)
              }

              // 手输坐标只是兜底（现场对不上时用），正常用上面的搜索
              TextInput({ placeholder: '地点名称（选完搜索结果会自动填）', text: this.formAddress })
                .height(42)
                .maxLength(128)
                .onChange((value: string) => {
                  this.formAddress = value;
                })
              Row({ space: 10 }) {
                TextInput({ placeholder: '纬度，如 30.572815', text: this.formLatitude })
                  .layoutWeight(1)
                  .height(42)
                  .maxLength(20)
                  .type(InputType.NUMBER_DECIMAL)
                  .onChange((value: string) => {
                    this.formLatitude = value;
                  })
                TextInput({ placeholder: '经度，如 104.066801', text: this.formLongitude })
                  .layoutWeight(1)
                  .height(42)
                  .maxLength(20)
                  .type(InputType.NUMBER_DECIMAL)
                  .onChange((value: string) => {
                    this.formLongitude = value;
                  })
              }
              .width('100%')
              TextInput({ placeholder: `打卡半径（米，50~1000，默认 ${DEFAULT_RADIUS_M}）`, text: this.formRadius })
                .height(42)
                .maxLength(4)
                .type(InputType.Number)
                .onChange((value: string) => {
                  this.formRadius = value;
                })
              Text('搜出来的坐标就是 GPS 坐标（WGS84，系统地理编码直接给），和后端要求一致，不用换算。' +
                '如果选出来的点跟现场差几百米（同名地点很多，注意看地址全称），直接到现场点「用当前位置」最准。')
                .fontSize(11)
                .fontColor('#FF8800')
                .width('100%')

              Row({ space: 8 }) {
                Text(`参与人员（已选 ${this.selectedIds.length} 人）`)
                  .fontSize(12)
                  .fontColor('#999999')
                Blank()
                Text('全选')
                  .fontSize(12)
                  .fontColor('#0A59F7')
                  .onClick(() => {
                    this.selectAllUsers();
                  })
                Text('清空')
                  .fontSize(12)
                  .fontColor('#0A59F7')
                  .margin({ left: 8 })
                  .onClick(() => {
                    this.clearAllUsers();
                  })
              }
              .width('100%')

              if (this.usersLoading) {
                Text('人员加载中...')
                  .fontSize(12)
                  .fontColor('#999999')
                  .width('100%')
                  .textAlign(TextAlign.Center)
              } else if (this.users.length === 0) {
                Text('没有可选人员，先去"人员管理"新建账号')
                  .fontSize(12)
                  .fontColor('#999999')
                  .width('100%')
                  .textAlign(TextAlign.Center)
              } else {
                ForEach(this.users, (user: UserListItem) => {
                  Row({ space: 10 }) {
                    Text(this.isSelected(user.id) ? '✓' : '')
                      .width(20)
                      .height(20)
                      .borderRadius(10)
                      .backgroundColor(this.isSelected(user.id) ? '#0A59F7' : '#F0F0F0')
                      .fontColor(Color.White)
                      .fontSize(12)
                      .textAlign(TextAlign.Center)
                    Column({ space: 2 }) {
                      Text(this.displayUser(user))
                        .fontSize(14)
                        .fontColor('#222222')
                      Text(user.role === ROLE_ADMIN ? `${user.userName} · 管理员` : user.userName)
                        .fontSize(11)
                        .fontColor('#999999')
                    }
                    .alignItems(HorizontalAlign.Start)
                    Blank()
                  }
                  .width('100%')
                  .height(44)
                  .onClick(() => {
                    this.toggleUser(user.id);
                  })
                }, (user: UserListItem) => `${user.id}_${this.isSelected(user.id)}`)
              }

              if (this.usersTotal > this.users.length) {
                Text(`共 ${this.usersTotal} 人，这里只能选前 ${this.users.length} 人`)
                  .fontSize(11)
                  .fontColor('#FF8800')
                  .width('100%')
              }

              if (this.panelTip.length > 0) {
                Text(this.panelTip)
                  .fontSize(12)
                  .fontColor('#E84026')
                  .width('100%')
                  .textAlign(TextAlign.Center)
              }

              Text('任务创建后不能修改、不能取消、不能删除，请确认好人员和时' + '间窗口再提交。')
                .fontSize(11)
                .fontColor('#999999')
                .width('100%')
            }
            .width('100%')
            .padding({ top: 4, bottom: 8 })
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)

          Row({ space: 12 }) {
            Button('取消')
              .layoutWeight(1)
              .height(42)
              .backgroundColor('#F0F0F0')
              .fontColor('#333333')
              .onClick(() => {
                this.closeCreate();
              })
            Button('创建任务')
              .layoutWeight(1)
              .height(42)
              .enabled(!this.loading)
              .onClick(() => {
                this.submitCreate().catch((err: Error) => {
                  this.panelTip = err.message;
                });
              })
          }
          .width('100%')
          .margin({ top: 8 })
        }
        .width('92%')
        .height('86%')
        .padding(16)
        .backgroundColor(Color.White)
        .borderRadius(16)
      }

      // ---- 任务详情面板 ----
      if (this.detailOpen) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => {
            this.closeDetail();
          })

        Column() {
          Row() {
            Text('任务详情')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
            Blank()
            Text('✕')
              .fontSize(16)
              .fontColor('#999999')
              .onClick(() => {
                this.closeDetail();
              })
          }
          .width('100%')
          .height(36)

          if (this.detailLoading) {
            Column() {
              LoadingProgress()
                .width(28)
                .height(28)
            }
            .width('100%')
            .height(160)
            .justifyContent(FlexAlign.Center)
          } else {
            Scroll() {
              Column({ space: 10 }) {
                Text(this.dTitle)
                  .fontSize(16)
                  .fontColor('#222222')
                  .width('100%')
                Row({ space: 8 }) {
                  Text(checkTypeText(this.dCheckType))
                    .fontSize(11)
                    .fontColor('#0A59F7')
                    .backgroundColor('#E8F0FF')
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .borderRadius(4)
                  Text(stateText(this.dState))
                    .fontSize(11)
                    .fontColor(this.stateColor(this.dState))
                  Blank()
                }
                .width('100%')
                Text(`${formatTaskTime(this.dStartAt)} ~ ${formatTaskTime(this.dEndAt)}`)
                  .fontSize(12)
                  .fontColor('#999999')
                  .width('100%')
                Text(`${this.dLatitude !== null && this.dLongitude !== null ? '📍' : '🌐'} ${this.detailLocationText()}`)
                  .fontSize(12)
                  .fontColor('#666666')
                  .width('100%')

                Text(`名单（共 ${this.participants.length} 人）`)
                  .fontSize(12)
                  .fontColor('#999999')
                  .width('100%')

                ForEach(this.participants, (item: AttendanceTaskParticipant) => {
                  Column({ space: 4 }) {
                    Row({ space: 10 }) {
                      Column({ space: 2 }) {
                        Text(this.displayParticipant(item))
                          .fontSize(14)
                          .fontColor('#222222')
                        Text(item.userName)
                          .fontSize(11)
                          .fontColor('#999999')
                      }
                      .alignItems(HorizontalAlign.Start)
                      Blank()
                      Column({ space: 2 }) {
                        Row({ space: 6 }) {
                          if (item.source === 'MANUAL') {
                            Text('补录')
                              .fontSize(10)
                              .fontColor('#FF8800')
                              .backgroundColor('#FFF3E0')
                              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                              .borderRadius(3)
                          }
                          Text(item.status === 'DONE' ? '已打卡' : '待打卡')
                            .fontSize(12)
                            .fontColor(item.status === 'DONE' ? '#37B24D' : '#999999')
                        }
                        if (item.checkedAt !== null) {
                          Text(formatTaskTime(item.checkedAt))
                            .fontSize(11)
                            .fontColor('#BBBBBB')
                        }
                      }
                      .alignItems(HorizontalAlign.End)
                    }
                    .width('100%')

                    // 管理操作：待打卡 → 补卡；MANUAL 记录 → 修改 / 撤销
                    Row({ space: 14 }) {
                      if (this.canManualCreate(item)) {
                        Text('补卡')
                          .fontSize(12)
                          .fontColor('#0A59F7')
                          .onClick(() => {
                            this.openManualCreate(item);
                          })
                      }
                      if (this.canManualEdit(item)) {
                        Text('修改')
                          .fontSize(12)
                          .fontColor('#0A59F7')
                          .onClick(() => {
                            this.openManualUpdate(item);
                          })
                        Text('撤销')
                          .fontSize(12)
                          .fontColor('#E84026')
                          .onClick(() => {
                            this.manualRecordId = item.recordId !== null ? item.recordId : 0;
                            this.manualUserText = this.displayParticipant(item);
                            this.revokeOpen = true;
                          })
                      }
                      Blank()
                    }
                    .width('100%')
                    .justifyContent(FlexAlign.End)

                    if (item.remark !== null && item.remark.length > 0) {
                      Text(`备注：${item.remark}`)
                        .fontSize(11)
                        .fontColor('#999999')
                        .width('100%')
                        .maxLines(2)
                    }
                  }
                  .width('100%')
                  .padding({ top: 8, bottom: 8 })
                }, (item: AttendanceTaskParticipant) =>
                  `${item.userId}_${item.status}_${item.checkedAt}_${item.source}_${item.recordId}_${item.remark}`)
              }
              .width('100%')
            }
            .layoutWeight(1)
            .width('100%')
            .scrollBar(BarState.Off)
          }

          Button('关闭')
            .width('100%')
            .height(42)
            .margin({ top: 8 })
            .backgroundColor('#F0F0F0')
            .fontColor('#333333')
            .onClick(() => {
              this.closeDetail();
            })
        }
        .width('92%')
        .height('86%')
        .padding(16)
        .backgroundColor(Color.White)
        .borderRadius(16)
      }

      // ---- 补卡 / 修改补卡面板 ----
      if (this.manualOpen) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => {
            this.closeManual();
          })

        Column({ space: 10 }) {
          Row() {
            Text(this.manualCreate ? '补卡' : '修改补卡')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
            Blank()
            Text('✕')
              .fontSize(16)
              .fontColor('#999999')
              .onClick(() => {
                this.closeManual();
              })
          }
          .width('100%')
          .height(32)

          Text(`给 ${this.manualUserText} ${this.manualCreate ? '补一条打卡记录' : '修改这条补卡记录'}`)
            .fontSize(13)
            .fontColor('#666666')
            .width('100%')

          Text('打卡时间（格式 2026-10-29 08:05）')
            .fontSize(12)
            .fontColor('#999999')
            .width('100%')
          TextInput({ placeholder: '打卡时间', text: this.manualCheckAt })
            .height(42)
            .maxLength(16)
            .onChange((value: string) => {
              this.manualCheckAt = value;
            })
          Row({ space: 8 }) {
            Text('填当前时间')
              .fontSize(12)
              .fontColor('#0A59F7')
              .onClick(() => {
                this.manualCheckAt = this.nowDateTimeText();
              })
            Blank()
          }
          .width('100%')

          Text('备注（可选，留空表示不写；修改时留空会清掉原备注）')
            .fontSize(12)
            .fontColor('#999999')
            .width('100%')
          TextInput({ placeholder: '例如 忘带手机，现场签到', text: this.manualRemark })
            .height(42)
            .maxLength(128)
            .onChange((value: string) => {
              this.manualRemark = value;
            })

          if (this.manualTip.length > 0) {
            Text(this.manualTip)
              .fontSize(12)
              .fontColor('#E84026')
              .width('100%')
              .textAlign(TextAlign.Center)
          }

          Row({ space: 12 }) {
            Button('取消')
              .layoutWeight(1)
              .height(42)
              .backgroundColor('#F0F0F0')
              .fontColor('#333333')
              .onClick(() => {
                this.closeManual();
              })
            Button(this.manualCreate ? '确认补卡' : '保存修改')
              .layoutWeight(1)
              .height(42)
              .enabled(!this.manualSaving)
              .onClick(() => {
                this.submitManual().catch((err: Error) => {
                  this.manualTip = err.message;
                });
              })
          }
          .width('100%')
          .margin({ top: 4 })
        }
        .width('88%')
        .padding(16)
        .backgroundColor(Color.White)
        .borderRadius(16)
      }

      // ---- 撤销补卡确认 ----
      if (this.revokeOpen) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => {
            this.revokeOpen = false;
          })

        Column({ space: 12 }) {
          Text('撤销补卡')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
          Text(`撤销后 ${this.manualUserText} 会回到"待打卡"状态，这条补卡记录作废。确定吗？`)
            .fontSize(13)
            .fontColor('#666666')
            .textAlign(TextAlign.Center)
          if (this.manualTip.length > 0) {
            Text(this.manualTip)
              .fontSize(12)
              .fontColor('#E84026')
              .textAlign(TextAlign.Center)
          }
          Row({ space: 12 }) {
            Button('再想想')
              .layoutWeight(1)
              .height(40)
              .backgroundColor('#F0F0F0')
              .fontColor('#333333')
              .onClick(() => {
                this.revokeOpen = false;
              })
            Button('确定撤销')
              .layoutWeight(1)
              .height(40)
              .backgroundColor('#E84026')
              .fontColor(Color.White)
              .enabled(!this.manualSaving)
              .onClick(() => {
                this.doRevoke().catch((err: Error) => {
                  this.manualTip = err.message;
                });
              })
          }
          .width('100%')
        }
        .width('80%')
        .padding(18)
        .backgroundColor(Color.White)
        .borderRadius(16)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F1F3F5')
  }
}
