# Unified App Tray

[![DMS Plugin](https://img.shields.io/badge/DankMaterialShell-plugin-4f7cff)](#)
[![Niri](https://img.shields.io/badge/Niri-focused-22a06b)](#)
[![Version](https://img.shields.io/badge/version-1.0.0-informational)](./CHANGELOG.md)
[![License](https://img.shields.io/badge/license-MIT-lightgrey)](./LICENSE)

Unified App Tray is a DankMaterialShell DankBar widget that merges the built-in
Running Apps and System Tray widgets into one compact launcher/focus strip.

It is built for Niri setups where tray icons should behave like app icons:
click an app that already has a window and the shell focuses it; click a
background app without a window and the app opens normally.

## Features

- Shows StatusNotifier system tray apps.
- Shows apps with currently open windows.
- Shows input method tray items such as Fcitx and IBus.
- Deduplicates tray apps that already have visible windows.
- Cycles between multiple windows of the same app.
- Preserves DMS tray icon tint settings.
- Uses DMS theme, icon sizing, hover states, and tooltips.

## Click Behavior

| Item type | Click result |
| --- | --- |
| App with an open window | Focuses that window. If multiple windows exist, repeated clicks cycle them. |
| Tray app without an open window | Calls the tray item's normal `activate()` action, usually opening the app window. |
| Input method tray item | Calls the tray item's normal `activate()` action, keeping language/input switching intact. |

## Requirements

- DankMaterialShell with plugin support.
- Quickshell.
- Niri for compositor-driven window focus.
- `python3` and `busctl` for tray-to-window matching.
- A StatusNotifier tray provider, normally already available in DMS.

The widget still displays tray items outside Niri, but focus-existing-window
behavior depends on Niri's compositor IPC.

## Installation

Clone this repository into your DMS plugin directory:

```bash
git clone https://github.com/dpxwz/unifiedAppTray.git \
  ~/.config/DankMaterialShell/plugins/unifiedAppTray
```

Enable the plugin:

```bash
dms ipc plugins enable unifiedAppTray
```

Then add `unifiedAppTray` to a DankBar section in DMS settings. For a clean
replacement, disable the built-in `runningApps` and `systemTray` widgets on the
same bar.

Restart DMS if the bar does not update immediately:

```bash
dms restart
```

## Recommended DankBar Layout

The widget is designed to sit where the system tray normally lives:

```json
{
  "id": "unifiedAppTray",
  "enabled": true
}
```

For the old widgets:

```json
{
  "id": "runningApps",
  "enabled": false
}
```

```json
{
  "id": "systemTray",
  "enabled": false
}
```

## How It Works

Unified App Tray combines two DMS data sources:

- `SystemTray.items.values` for background tray apps and input methods.
- `CompositorService.sortedToplevels` for currently open windows.

On Niri, it also uses `NiriService.windows` and compositor IPC to focus windows
directly. This avoids the common Wayland limitation where applications cannot
raise their own existing windows from a tray activation request.

The matching strategy is intentionally conservative:

- First match tray item owners to process trees and window PIDs.
- Fall back to normalized tray names, tooltip names, icon names, and process
  names against Niri `app_id` values.
- Treat Fcitx, IBus, and input-method tray items as switchers, not app windows.

## Troubleshooting

Check plugin status:

```bash
dms ipc plugins list | grep unifiedAppTray
dms ipc widget list | grep unifiedAppTray
```

Read DMS logs:

```bash
qs -p /usr/share/quickshell/dms log | tail -n 200
```

If a specific tray app does not focus correctly, verify that Niri reports a
useful `app_id` for it:

```bash
niri msg -j windows
```

Set `DMS_TRAY_NO_FOCUS=1` before launching DMS to disable the focus override and
fall back to plain tray activation.

## Development

Useful local commands:

```bash
dms ipc plugins reload unifiedAppTray
dms restart
qs -p /usr/share/quickshell/dms log | tail -n 200
```

Create a release archive from a clean checkout:

```bash
git archive --format=zip \
  --prefix=unifiedAppTray-1.0.0/ \
  --output=unifiedAppTray-v1.0.0.zip \
  HEAD
```

## License

MIT License. See [LICENSE](./LICENSE).
