import {
  MyAttendanceTask,
  MyAttendanceTaskPage,
  STATE_OPEN,
  STATE_UPCOMING,
  checkTypeText,
  formatTaskTime,
  pageMyAttendanceTasks,
  stateText
} from '../api/Attendance';
import { gotoLogin } from '../utils/AuthStore';
import { BottomTabs } from '../components/BottomTabs';
import { isForbidden, isUnauthorized } from '../utils/HttpUtil';

/**
 * 我的考勤（所有登录用户，对应联调文档第 6 节）。
 *
 *   GET /attendance/task/mine?pageNum=&pageSize=
 *
 * 几个关键点：
 *   - 不用传 userId，后端只认 token
 *   - 没录满 10 个声纹数字时后端返回 HTTP 403 + "请先完成声纹注册"，
 *     这不是登录失效，不能清 token，只提示并引导去录声纹
 *   - state / done 都由后端算好，前端按文档 6 节的说法展示：
 *       done === true            → 已完成
 *       state === UPCOMING       → 未开始
 *       state === CLOSED         → 已结束
 *       state === OPEN && !done  → 去打卡（打卡接口后端还没提供）
 */
/** 跳到打卡页时带的参数（打卡页用 router.getParams() 取） */
interface CheckinRouteParams {
  taskId: number;
  title: string;
  checkType: string;
  startAt: string;
  endAt: string;
  /** 不限位置的任务不传，别传 null，类型对不上 */
  latitude?: number;
  longitude?: number;
  radiusM?: number;
  address?: string;
}

@Entry
@ComponentV2
struct MyTasks {
  @Local list: MyAttendanceTask[] = [];
  @Local pageNum: number = 1;
  @Local pageSize: number = 10;
  @Local total: number = 0;
  @Local pages: number = 0;
  @Local loading: boolean = false;
  @Local tip: string = '';
  /** 403 "请先完成声纹注册" 时置 true，整页换成引导卡片 */
  @Local needEnroll: boolean = false;
  /** 第一次显示由 aboutToAppear 负责加载，避免进页面请求两次 */
  private firstShow: boolean = true;

  aboutToAppear(): void {
    this.load();
  }

  onPageShow(): void {
    // 从声纹注册页 / 打卡页返回时重新拉一次：录满 10 个数字、打完卡都要刷新状态
    if (this.firstShow) {
      this.firstShow = false;
      return;
    }
    this.pageNum = 1;
    this.load();
  }

  /* ==================== 数据 ==================== */

  async load(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    this.tip = '';
    try {
      const page: MyAttendanceTaskPage = await pageMyAttendanceTasks(this.pageNum, this.pageSize);
      this.list = page.records;
      this.total = page.total;
      this.pages = page.pages;
      this.pageNum = page.pageNum;
      this.needEnroll = false;
      this.loading = false;
    } catch (err) {
      this.loading = false;
      if (isUnauthorized(err)) {
        await gotoLogin(this.getUIContext());
        return;
      }
      if (isForbidden(err)) {
        // 403 且提示是声纹的事：这不是没登录，只是还没录声纹
        this.needEnroll = true;
        this.list = [];
        return;
      }
      this.tip = (err as Error).message;
    }
  }

  /* ==================== 跳转 ==================== */

  async openVoiceprint(): Promise<void> {
    try {
      await this.getUIContext().getRouter().pushUrl({ url: 'pages/Voiceprint' });
    } catch (err) {
      console.error(`打开声纹注册失败: ${JSON.stringify(err)}`);
    }
  }

  /** 去打卡：把任务信息和打卡点坐标一起带过去，打卡页不用再多请求一次 */
  async openCheckin(item: MyAttendanceTask): Promise<void> {
    const params: CheckinRouteParams = {
      taskId: item.taskId,
      title: item.title,
      checkType: item.checkType,
      startAt: item.startAt,
      endAt: item.endAt
    };
    // 不限位置的任务不带坐标：后端会按"不校验位置"处理
    if (item.latitude !== null && item.longitude !== null) {
      params.latitude = item.latitude;
      params.longitude = item.longitude;
      if (item.radiusM !== null) {
        params.radiusM = item.radiusM;
      }
      if (item.address !== null) {
        params.address = item.address;
      }
    }
    try {
      await this.getUIContext().getRouter().pushUrl({ url: 'pages/Checkin', params: params });
    } catch (err) {
      console.error(`打开打卡页失败: ${JSON.stringify(err)}`);
      this.toast('打开打卡页失败，请重试');
    }
  }

  /** 任务有没有打卡点 */
  hasLocation(item: MyAttendanceTask): boolean {
    return item.latitude !== null && item.longitude !== null;
  }

  /** 地点文案：有坐标显示地址，没坐标显示"不限位置" */
  locationText(item: MyAttendanceTask): string {
    if (!this.hasLocation(item)) {
      return '不限位置';
    }
    if (item.address !== null && item.address.length > 0) {
      return item.address;
    }
    return `打卡点 ${item.latitude}, ${item.longitude}`;
  }

  /* ==================== 翻页 ==================== */

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

  /** 右侧状态/动作文案：先看 done，再看 state */
  actionText(item: MyAttendanceTask): string {
    if (item.done) {
      return '已完成';
    }
    if (item.state === STATE_OPEN) {
      return '去打卡';
    }
    if (item.state === STATE_UPCOMING) {
      return '未开始';
    }
    return '已结束';
  }

  actionColor(item: MyAttendanceTask): string {
    if (item.done) {
      return '#999999';
    }
    return item.state === STATE_OPEN ? '#0A59F7' : '#BBBBBB';
  }

  /** 只有"进行中且没打卡"才允许点，其它状态点了也没意义 */
  canCheckIn(item: MyAttendanceTask): boolean {
    return !item.done && item.state === STATE_OPEN;
  }

  /* ==================== 界面 ==================== */

  build() {
    Column() {
      // ---- 顶部栏（底部标签切页，不再需要返回箭头）----
      Row({ space: 4 }) {
        Text('考勤')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
        Blank()
        if (this.loading) {
          LoadingProgress() // 转圈动画
            .width(18)
            .height(18)
        }
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .backgroundColor(Color.White)

      if (this.needEnroll) {
        // ---- 声纹没录齐：整页换成引导 ----
        Column({ space: 14 }) {
          Text('🎤')
            .fontSize(40)
          Text('请先完成声纹注册')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
          Text('考勤打卡要用声纹验证身份，需要先录满 10 个数字（0~9 各一条）。')
            .fontSize(13)
            .fontColor('#666666')
            .textAlign(TextAlign.Center)
            .width('100%')
          Text('一次只念一个数字，0.5~1.5 秒，安静环境下录质量分会更高。')
            .fontSize(12)
            .fontColor('#999999')
            .textAlign(TextAlign.Center)
            .width('100%')
          Button('去录制声纹')
            .height(42)
            .width('80%')
            .fontColor(Color.White)
            .backgroundColor('#0A59F7')
            .onClick(() => {
              this.openVoiceprint().catch((err: Error) => {
                this.tip = err.message;
              });
            })
          Button('重新检查')
            .height(42)
            .width('80%')
            .fontSize(14)
            .fontColor('#0A59F7')
            .backgroundColor('#E8F0FF')
            .enabled(!this.loading)
            .onClick(() => {
              this.load();
            })
        }
        .width('86%')
        .padding(22)
        .margin({ top: 60 })
        .backgroundColor(Color.White)
        .borderRadius(16)
        .alignItems(HorizontalAlign.Center)
      } else if (this.list.length === 0) {
        Column() {
          Text(this.loading ? '加载中...' : '暂时没有安排给你的考勤任务')
            .fontSize(14)
            .fontColor('#999999')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          ForEach(this.list, (item: MyAttendanceTask) => {
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

                Row({ space: 6 }) {
                  Text(this.hasLocation(item) ? '📍' : '🌐')
                    .fontSize(12)
                  Text(this.locationText(item))
                    .fontSize(12)
                    .fontColor('#666666')
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (this.hasLocation(item) && item.radiusM !== null) {
                    Text(`半径 ${item.radiusM} 米`)
                      .fontSize(11)
                      .fontColor('#999999')
                  }
                }
                .width('100%')

                Row({ space: 8 }) {
                  if (item.checkedAt !== null) {
                    Text(`打卡时间 ${formatTaskTime(item.checkedAt)}`)
                      .fontSize(12)
                      .fontColor('#999999')
                  } else {
                    Text('还没打卡')
                      .fontSize(12)
                      .fontColor('#999999')
                  }
                  Blank()
                  Text(this.actionText(item))
                    .fontSize(13)
                    .fontColor(this.actionColor(item))
                    .fontWeight(this.canCheckIn(item) ? FontWeight.Medium : FontWeight.Normal)
                    .onClick(() => {
                      if (this.canCheckIn(item)) {
                        this.openCheckin(item).catch((err: Error) => {
                          this.tip = err.message;
                        });
                      }
                    })
                }
                .width('100%')
              }
              .width('100%')
              .padding(14)
              .backgroundColor(Color.White)
              .borderRadius(12)
            }
            // done / state 变了要重新渲染
          }, (item: MyAttendanceTask) => `${item.taskId}_${item.state}_${item.done}_${item.checkedAt}`)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16, top: 12 })
        .scrollBar(BarState.Off)

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
      }

      // ---- 错误提示 ----
      if (this.tip.length > 0) {
        Text(this.tip)
          .fontSize(13)
          .fontColor('#E84026')
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ left: 16, right: 16, bottom: 8 })
      }

      // 底部标签：考勤 / 我的（管理员还有两个管理页）
      BottomTabs({ current: 'tasks' })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F1F3F5')
  }
}
