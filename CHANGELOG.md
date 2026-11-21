# Changelog

本项目格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [2.1.0] — 2026-11-21

近期路线三项落地。

### 新增

- 按可用宽度自动收纳（`autoOverflow`，默认开）：DMS 会把分区可用尺寸注入
  `sectionAvailablePrimarySize`，插件据此算出能放下几个图标，放不下的收进
  溢出菜单；与内置托盘同一套 DPR 换算。固定数量上限（`maxVisibleItems`）
  仍然生效，两者取较小值。
- 工作区过滤（`filterByWorkspace`，默认关）：只显示当前工作区的窗口，走
  `CompositorService.filterCurrentWorkspace`，与内置运行应用行为一致；
  工作区切换即时重算（监听 `workspaceStateChanged`）。
- 红点点击即清（`attentionClickDismiss`，默认开）：点击带角标的托盘图标，
  角标立即熄灭；应用自己撤销 SNI 状态后，下一次提醒能重新亮起。
- 设置页新增三个对应开关。

### 修复

- 运行中的固定应用无法拖动排序（1.4.x 合并逻辑遗留）：合并体保留窗口
  kind，拖拽判定只认纯固定 kind，应用退出前图标被冻结。改为按
  `isPinned` 判定，运行中 / 有托盘 / 纯固定三种状态都可拖。

## [2.0.0] — 2026-11-21

基于 1.4.1 的重构版本。交互对齐内置 dock，匹配逻辑统一，核心算法抽出可测。

### 新增

- 滚轮切换同应用窗口：鼠标滚轮步进一次，触控板输入按阈值累积（对齐内置 RunningApps）。
- 中键操作：窗口项关闭当前窗口，托盘项调用 SNI `SecondaryActivate`。
- 托盘 `NeedsAttention` 状态：图标角落闪烁红点（`showAttentionDots`，默认开）。
- 托盘 `Passive` 状态：无窗口的闲置项淡化显示（`dimPassiveItems`，默认开）。
- 拖拽排序：按住托盘/固定图标拖动调整顺序；托盘顺序写入 `SessionData.trayItemOrder`，
  与内置系统托盘互通；固定应用顺序写入 `SessionData.barPinnedApps`。
- 托盘 tooltip 带上 `tooltipDescription` 副标题。
- `onlyMenu` 托盘项左键直接开菜单（此前只有右键能开，且依赖硬编码 fallback）。
- `js/Matching.js`：统一匹配核心（norm 缓存、打分、宽松包含），QML 与 Node 共用。
- `tests/test_matching.js`：31 个用例的零依赖单测。

### 修复

- 图标闪烁：ScriptModel 身份 key 不再包含标题/tooltip（改用
  `TrayMenuManager.getTrayItemKey` 稳定 key），托盘应用改标题（VPN 状态、
  传输速率等）不再销毁重建 delegate。
- 去重判定不一致：`entryMatchesPinnedId` 现在与窗口匹配共用宽松包含口径，
  固定 id / 运行窗口 / 托盘图标对「同一应用」判定一致，不再重复渲染。
- 点击行为绕过 DMS：窗口激活统一走 `CompositorService.toggleToplevel` /
  `activateToplevel`，最小化恢复与 Niri overview 关闭由 DMS 统一处理，
  不再直接调 `toplevel.activate()`。
- `skipSwitcher` 窗口不再进入列表（对齐内置 RunningApps）。

### 变更

- PID 扫描脚本外置为 `scripts/tray_pid_scan.py`（逻辑不变，输出逐字节一致）。
- 扫描心跳从 30 秒放缓到 5 分钟（托盘增删仍即时重扫）。
- `norm()` 等热路径函数带 memo 缓存（2000 条上限）。
- 版本号 1.4.1 → 2.0.0；README 重写并新增本 CHANGELOG。

### 移除

- QML 内嵌 Python 脚本字符串（约 110 行）。

## [1.4.1] — 上游

dpxwz/unifiedAppTray 最终发布版，作为本 fork 的基线。
