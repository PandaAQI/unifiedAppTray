# Unified App Tray（统一应用托盘）

[![DMS Plugin](https://img.shields.io/badge/DankMaterialShell-plugin-4f7cff)](#)
[![Niri](https://img.shields.io/badge/Niri-focused-22a06b)](#)
[![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)](./LICENSE)
[![Tests](https://img.shields.io/badge/tests-node%20js/Matching.js-2ea44f)](./tests)

DankMaterialShell DankBar 小部件：把「固定应用」「运行窗口」「系统托盘」合并成一条，
点击即可聚焦或启动。Unified App Tray merges DMS's pinned apps, running
windows and StatusNotifier tray into one compact launcher/focus strip.

> Fork of dpxwz/unifiedAppTray 1.4.1 (upstream no longer published), rebuilt
> with dock-grade interaction, a unified matching core and tests.

## 功能一览

| 操作 | 行为 |
| --- | --- |
| 左键（有窗口） | 单窗口聚焦/最小化切换；多窗口循环切换 |
| 左键（托盘应用） | 聚焦已有窗口，否则激活托盘；只有菜单的托盘项直接开菜单 |
| 左键（固定应用） | 启动应用；已有窗口时先聚焦 |
| 中键 | 窗口项：关闭当前窗口；托盘项：调用 SNI `SecondaryActivate` |
| 右键 | 应用菜单（窗口列表 + 固定 + 新建窗口 + 关闭） |
| 滚轮 | 在同应用的多个窗口间切换（支持触控板累积阈值） |
| 按住拖动 | 调整托盘图标 / 固定应用顺序，与内置托盘顺序互通 |
| 角标 | 托盘报告 `NeedsAttention` 时图标角落闪烁红点 |
| 淡化 | 无窗口的 `Passive` 托盘项降低不透明度 |

其他能力：

- 托盘项与窗口的去重共用同一套匹配口径（精确 + 宽松包含），不再出现同一应用画两次。
- 图标身份 key 与 DMS 内置托盘一致（`TrayMenuManager.getTrayItemKey`），标题变化不再导致闪烁。
- 尊重 `skip_switcher` 的窗口不进列表（与内置 RunningApps 相同）。
- 托盘图标着色、悬停放大、指示点、溢出菜单、隐藏项恢复等原有能力全部保留。
- PID 扫描脚本外置为 `scripts/tray_pid_scan.py`（`python3` + `busctl`），可独立运行与调试。

## 环境要求

- DankMaterialShell（含插件系统）+ Quickshell
- Niri（聚焦/最小化走 `CompositorService`，窗口聚焦在其他合成器上由 Quickshell toplevel 后端兜底）
- `python3`、`busctl`（托盘→窗口 PID 匹配）
- Node.js（仅跑测试时需要）

## 安装

```bash
git clone https://github.com/<你的用户名>/unifiedAppTray.git \
  ~/.config/dms/plugins/unifiedAppTray

dms ipc plugins enable unifiedAppTray
```

在 DMS 设置里把 `unifiedAppTray` 加进 DankBar 任意分区；建议关掉同栏的内置
`runningApps` 与 `systemTray`：

```json
{ "id": "runningApps", "enabled": false }
```

```json
{ "id": "systemTray", "enabled": false }
```

改完不生效就重启：

```bash
dms restart
```

## 配置项

设置入口：DMS 设置 → 插件 → 统一应用托盘。

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `showPinnedApps` | true | 显示固定应用 |
| `showRunningApps` | true | 显示运行窗口 |
| `showTrayItems` | true | 显示托盘/输入法图标 |
| `dedupeApps` | true | 三源去重，固定优先 |
| `showAttentionDots` | true | NeedsAttention 闪烁角标 |
| `dimPassiveItems` | true | 淡化闲置托盘项 |
| `showIndicators` | true | 运行指示点 |
| `enlargeOnHover` / `enlargePercentage` | true / 125 | 悬停放大 |
| `iconSizePercent` | 100 | 图标大小（50–200%） |
| `itemSpacing` | 4 | 图标间距（px） |
| `maxVisibleItems` | 0 | 超出收进溢出菜单，0 = 全部显示 |
| `showOverflowBadge` | true | 溢出按钮 +N 角标 |
| `showLauncherButton` | false | 在最前显示启动器按钮 |

## 工作原理

三个数据源合成一条列表：

1. **固定应用**：`SessionData.barPinnedApps`（与内置 dock 共用）。
2. **运行窗口**：`CompositorService.sortedToplevels`（过滤 `skipSwitcher`）。
3. **托盘**：`SystemTray.items.values`（尊重 `SessionData.trayItemOrder` 顺序与手动隐藏）。

托盘项与窗口的关联链：PID 子树精确匹配 → 进程名/托盘名打分 → desktop entry
兜底，全部实现在 `js/Matching.js`（纯函数、零 Qt 依赖）。固定应用判定在精确
匹配之上增加宽松包含匹配，保证「固定 id ↔ 窗口 ↔ 托盘图标」对同一应用判定一致。

点击行为统一走 `CompositorService.activateToplevel` / `toggleToplevel`（自动处理
最小化恢复与 Niri overview 关闭）；Niri 独有窗口走 `NiriService.focusWindow`。

托盘 PID 扫描：`scripts/tray_pid_scan.py` 通过 `busctl` 枚举 SNI 项、解析
连接 PID 并展开进程子树。心跳间隔 5 分钟（托盘增删会即时重扫），单项约 0.1s。

调试开关：`DMS_TRAY_NO_FOCUS=1` 环境变量可禁用「聚焦已有窗口」覆盖逻辑。

## 开发

```bash
# 匹配库单测（Node，零依赖）
node tests/test_matching.js

# 独立运行 PID 扫描脚本
python3 scripts/tray_pid_scan.py

# 改动后热重载
dms ipc plugins reload unifiedAppTray

# 看 DMS 日志
qs -p /run/user/$(id -u)/dms-shell/*/log | tail -n 50
```

目录结构：

```
UnifiedAppTrayWidget.qml     交互主体（列表、菜单、拖拽、点击/滚轮语义）
UnifiedAppTraySettings.qml    设置页
js/Matching.js                统一匹配核心（QML 与 Node 共用）
scripts/tray_pid_scan.py      托盘 PID/进程名扫描（QML Process 调用）
tests/test_matching.js         Matching.js 单测
```

## 许可

MIT，见 [LICENSE](./LICENSE)。基于 dpxwz/unifiedAppTray 1.4.1，原作者署名保留于 LICENSE 与本节。
