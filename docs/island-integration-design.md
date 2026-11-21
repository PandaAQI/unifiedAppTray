# unifiedAppTray × 灵动岛 联动方案设计

状态：**方案设计，未实施**（2026-11-21）。结论：可行，且不止一条路；
推荐路线见文末。

## 背景

- 插件实例已经挂在岛 bar（bar0）的 left / center 两翼，物理上是岛的一部分，
  缺的是**行为联动**。
- DMS 岛的活动页（home / media / notifications / clipboard …）由
  `IslandController.requestActivity()` 切换，且该能力已被封装到全局单例
  `PopoutService.routeToIsland(activityId, screen, shouldToggle, section, barId)`
  （Services/PopoutService.qml:216，pragma Singleton）。插件与 DMS 同 QML
  引擎，`import qs.Services` 后可直接调用——插件里调
  `PopoutService.toggleDankLauncherV2()` 已有先例，通道验证可用。
- 岛 home 的时钟已有 `clockNotificationBadge`（读 unreadNotificationCount），
  即**通知流数据天然出现在岛上**。

## 路线 A：托盘红点 → 桌面通知流（推荐首选）

机制：插件检测到 SNI NeedsAttention **首次出现**时，通过 Quickshell
Process 调 `notify-send`（或 Notifications DBus）发一条低优先级通知。
岛上立即得到两个原生表现：home 时钟角标 +1；通知横幅从岛弹出。
用户点开通知中心可看到哪个应用在喊。

- 改动面：纯插件侧，约 60–80 行（去重逻辑：同一 app 红点持续期间只发
  一次；应用自己撤销状态后允许再次提醒）。
- 风险：横幅打扰——做成插件设置开关（默认关），并可按 app 加白名单。
- 评价：**零 DMS fork 改动**，全部走 DMS 原生管道，升级无冲突，性价比最高。

## 路线 B：媒体类托盘项点击 → 岛切到 media 页

机制：右键菜单加一项「在岛上打开媒体」，调
`PopoutService.routeToIsland("media", root.parentScreen, false, "")`；
识别靠 SNI Category === "AudioVideo" 或 app id 白名单（Spotify、mpv 等）。

- 改动面：纯插件侧，约 30 行（菜单项 + 识别 + 调用）。
- 风险：与岛自带的媒体条内容重叠（岛本来就有当前播放），价值偏弱；
  适合做成「跳转」而非「展示」。
- 评价：可行但优先级低；哥哥左键习惯不改，只加右键入口最稳。

## 路线 C：插件溢出菜单注册成岛活动页（不推荐）

机制：岛的活动页注册表在 `Modules/DIsland/Activities/`（硬编码目录 +
`IslandController` 状态机），没有插件注册接口。要做只能改 DMS fork：
新增 Activity 文件 + DIslandSurface 的 face 路由 + IslandController 状态。

- 改动面：DMS fork 大改（3 个文件起步），随每次 DMS 升级重打补丁。
- 评价：**可行但维护成本高**，与「插件自治」的设计初衷冲突，搁置。

## 其他排除项

- 卫星（islandSatellitesEnabled）实为展开态浮动面板，不是挂 widget 的
  槽位——「托盘条挂上岛体」无现成机制。
- 拖图标到岛 = 固定进岛：niri/DMS 均无此 hook，无实现路径。

## 推荐结论

1. **A 优先**：通知流是 DMS 原生的岛数据源，插件零成本接入，开关默认关。
2. B 作为右键菜单的轻量补充，随手可加。
3. C 搁置，除非将来 DMS 官方开放 Activity 注册接口。
