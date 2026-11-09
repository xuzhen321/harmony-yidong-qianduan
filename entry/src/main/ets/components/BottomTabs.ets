/**
 * 底部标签栏。
 *
 * 为什么不用 Tabs 组件：现在的「我的」「考勤」「人员管理」「考勤管理」都是独立页面（@Entry），
 * 每个页面自己 onPageShow 拉数据。改成 Tabs 要把四个页面的生命周期全重写一遍，
 * 风险大得多；这里用「固定底部栏 + replaceUrl 切页」效果一样，而且切过去一定是新数据。
 *
 * 谁看见哪些标签由角色决定：普通用户只有「考勤」「我的」，管理员多两个管理页。
 */
import { isAdmin } from '../utils/AuthStore';

/** 标签对应的页面路由 */
export const TAB_MY_TASKS: string = 'pages/MyTasks';
export const TAB_PROFILE: string = 'pages/Index';
export const TAB_ADMIN_USERS: string = 'pages/AdminUsers';
export const TAB_ADMIN_TASKS: string = 'pages/AttendanceTasks';

/** 当前页是哪个标签 */
export type TabKey = 'tasks' | 'profile' | 'users' | 'adminTasks';

interface TabItem {
  key: TabKey;
  label: string;
  icon: string;
  url: string;
}

/** 按角色列出所有标签，顺序固定：考勤 / 考勤管理 / 人员管理 / 我的 */
function tabItems(): TabItem[] {
  const items: TabItem[] = [
    { key: 'tasks', label: '考勤', icon: '🗓', url: TAB_MY_TASKS }
  ];
  if (isAdmin()) {
    items.push({ key: 'adminTasks', label: '考勤管理', icon: '📋', url: TAB_ADMIN_TASKS });
    items.push({ key: 'users', label: '人员管理', icon: '👥', url: TAB_ADMIN_USERS });
  }
  items.push({ key: 'profile', label: '我的', icon: '👤', url: TAB_PROFILE });
  return items;
}

@ComponentV2
export struct BottomTabs {
  /** 当前页面标识，用来高亮 */
  @Param current: TabKey = 'profile';

  /** 当前标签：蓝字 + 淡蓝底，其他灰色 */
  @Builder
  tabCell(item: TabItem) {
    Column({ space: 2 }) {
      Text(item.icon)
        .fontSize(19)
      Text(item.label)
        .fontSize(11)
        .fontColor(item.key === this.current ? '#0A59F7' : '#666666')
        .maxLines(1)
    }
    .layoutWeight(1) // 设置为1表示平分宽度
    .height(46)
    .justifyContent(FlexAlign.Center)  // 居中显示
    .backgroundColor(item.key === this.current ? '#F0F5FF' : Color.Transparent)  // 蓝色或者没有底色
    .borderRadius(10) // 设置为圆角 半径10vp
    .onClick(() => {
      if (item.key === this.current) {
        return;
      }
      try {
        this.getUIContext().getRouter().replaceUrl({ url: item.url });
      } catch (err) {
        console.error(`切换页面失败: ${JSON.stringify(err)}`);
      }
    })
  }

  build() {
    Row({ space: 4 }) {
      ForEach(tabItems(), (item: TabItem) => {
        this.tabCell(item)
      }, (item: TabItem) => `${item.key}_${item.key === this.current}`)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .backgroundColor(Color.White)
  }
}
