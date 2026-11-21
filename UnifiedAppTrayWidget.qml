import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Services.SystemTray
import Quickshell.Widgets
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.DBar.Widgets as DBarWidgets
import qs.Modules.Plugins
import qs.Services
import qs.Widgets
import "js/Matching.js" as Matching

PluginComponent {
    id: root

    layerNamespacePlugin: "unified-app-tray"

    property int _desktopEntriesUpdateTrigger: 0
    property int _toplevelsUpdateTrigger: 0
    property int _appIdSubstitutionsTrigger: 0
    property int _trayOrderTrigger: 0
    property var trayPidMap: ({})
    property var trayNameMap: ({})
    property var hoveredItem: null
    property var delegateItems: []
    property bool isAutoHideBar: false
    // Live drag state, shared across delegates through the root so siblings
    // can shift out of the way. Null when idle.
    // { kind, trayKey, pinnedIndex, pressX, pressY, dragging, visualOffset, targetIndex }
    property var dragState: null
    readonly property bool isAtBottom: root.axis?.edge === "bottom"
    readonly property real minTooltipY: {
        if (!parentScreen || !root.isVertical) {
            return 0;
        }

        if (root.isAutoHideBar) {
            return 0;
        }

        if (parentScreen.y > 0) {
            const estimatedTopBarHeight = barThickness + barSpacing;
            return estimatedTopBarHeight;
        }

        return 0;
    }
    property bool menuOpen: false
    property var currentTrayMenu: null

    // Per-app fallbacks for tray items that do not implement Activate().
    // Key: tray item id (lowercase). Value: argv passed to Quickshell.execDetached.
    // Steam's Linux tray is the known offender: it exposes a menu but no Activate.
    readonly property var activateFallbacks: ({
        "steam": ["steam", "steam://open/main"],
        "flclash": ["flclash"]
    })
    property string _lastFallbackKey: ""
    property double _lastFallbackAt: 0

    // ---- User configuration (written by UnifiedAppTraySettings.qml) ----
    readonly property var cfg: root.pluginData || ({})
    readonly property bool showPinnedApps: root.cfg.showPinnedApps !== false
    readonly property bool showRunningApps: root.cfg.showRunningApps !== false
    readonly property bool showTrayItems: root.cfg.showTrayItems !== false
    readonly property bool showLauncherButton: root.cfg.showLauncherButton === true
    readonly property bool dedupeApps: root.cfg.dedupeApps !== false
    readonly property bool showIndicators: root.cfg.showIndicators !== false
    readonly property bool showOverflowBadge: root.cfg.showOverflowBadge !== false
    readonly property bool showAttentionDots: root.cfg.showAttentionDots !== false
    readonly property bool dimPassiveItems: root.cfg.dimPassiveItems !== false
    readonly property bool enlargeOnHover: root.cfg.enlargeOnHover !== false
    readonly property int enlargePercentage: {
        const value = Number(root.cfg.enlargePercentage ?? 125);
        if (isNaN(value))
            return 125;
        return Math.max(105, Math.min(160, value));
    }
    readonly property int iconSizePercent: {
        const value = Number(root.cfg.iconSizePercent ?? 100);
        if (isNaN(value))
            return 100;
        return Math.max(50, Math.min(200, value));
    }
    readonly property int itemSpacingSetting: {
        const value = Number(root.cfg.itemSpacing ?? Theme.spacingXS);
        if (isNaN(value))
            return Theme.spacingXS;
        return Math.max(0, Math.min(24, value));
    }
    readonly property int maxVisibleItems: {
        const value = Number(root.cfg.maxVisibleItems ?? 0);
        if (isNaN(value))
            return 0;
        return Math.max(0, Math.min(50, value));
    }

    readonly property real baseIconPixels: Theme.barIconSize(root.barThickness, undefined, root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)
    readonly property real iconPixels: Math.max(8, Math.round(root.baseIconPixels * root.iconSizePercent / 100))
    // Mirror the dock's indicator lane so icons sit on the same optical grid.
    readonly property real indicatorLane: root.showIndicators ? Math.max(8, Math.round(root.iconPixels * 0.18)) : 0
    readonly property real crossSizeLimit: root.widgetThickness > 0 ? root.widgetThickness : root.iconPixels + root.indicatorLane * 2
    readonly property real itemCrossSize: Math.max(root.iconPixels, Math.min(root.iconPixels + root.indicatorLane * 2, root.crossSizeLimit))
    readonly property real indicatorThickness: Math.max(0, (root.itemCrossSize - root.iconPixels) / 2)
    readonly property real itemSize: root.itemCrossSize
    readonly property var availableTrayItems: TrayMenuManager.filterEnvHidden(SystemTray.items.values || [])
    readonly property var userHiddenTrayItems: {
        SessionData.hiddenTrayIds;
        return root.availableTrayItems.filter(item => SessionData.isHiddenTrayId(root.getTrayItemKey(item)));
    }
    // Honour the same persisted order as the built-in SystemTrayBar
    // (SessionData.trayItemOrder), so tray ordering edited anywhere is
    // respected here too. Items without a saved position keep their
    // registration order.
    readonly property var sortedTrayItems: {
        root._trayOrderTrigger;
        const saved = SessionData.trayItemOrder || [];
        return TrayMenuManager.sortByPreferredOrder(root.availableTrayItems || [], saved);
    }
    readonly property var allTrayItems: {
        SessionData.hiddenTrayIds;
        return root.sortedTrayItems.filter(item => !SessionData.isHiddenTrayId(root.getTrayItemKey(item)));
    }
    readonly property var hiddenTrayEntries: root.userHiddenTrayItems.map(item => ({
        "key": "hidden-tray:" + root.trayItemKey(item),
        "kind": "hiddenTrayItem",
        "trayItem": item,
        "windows": [],
        "niriWindows": [],
        "appId": "",
        "iconSource": root.trayIconSourceFor(item),
        "fallbackText": root.trayFallbackText(item),
        "tooltipText": root.trayTitle(item),
        "windowCount": 0,
        "isFocused": false,
        "isPinned": false
    }))
    readonly property var sortedToplevels: {
        _toplevelsUpdateTrigger;
        return CompositorService.sortedToplevels || [];
    }
    readonly property var windowGroups: buildWindowGroups(sortedToplevels)
    readonly property var unifiedItems: buildUnifiedItems()
    readonly property var displayedItems: buildDisplayedItems()

    readonly property string trayIconTintMode: {
        const configuredMode = SettingsData.systemTrayIconTintMode || "none";
        switch (configuredMode) {
        case "monochrome":
        case "primary":
        case "secondary":
            return configuredMode;
        default:
            return "none";
        }
    }
    readonly property bool trayIconTintEnabled: trayIconTintMode !== "none"
    readonly property real trayIconTintSaturationAmount: {
        const raw = SettingsData.systemTrayIconTintSaturation;
        const value = (raw === undefined || raw === null) ? 50 : raw;
        return Math.max(0, Math.min(100, value)) / 100;
    }
    readonly property real trayIconTintStrengthAmount: {
        const raw = SettingsData.systemTrayIconTintStrength;
        const value = (raw === undefined || raw === null) ? 135 : raw;
        return Math.max(0, Math.min(200, value)) / 100;
    }
    readonly property real trayIconSaturation: {
        switch (trayIconTintMode) {
        case "monochrome":
            return -1;
        case "primary":
        case "secondary":
            return -root.trayIconTintSaturationAmount;
        default:
            return 0;
        }
    }
    readonly property real trayIconColorization: {
        switch (trayIconTintMode) {
        case "primary":
        case "secondary":
            return root.trayIconTintStrengthAmount;
        default:
            return 0;
        }
    }
    readonly property color trayIconTintColor: {
        switch (trayIconTintMode) {
        case "primary":
            return Theme.primary;
        case "secondary":
            return Theme.secondary;
        default:
            return Theme.surfaceText;
        }
    }

    Connections {
        target: CompositorService

        function onToplevelsChanged() {
            root._toplevelsUpdateTrigger++;
        }
    }

    Connections {
        target: DesktopEntries

        function onApplicationsChanged() {
            root._desktopEntriesUpdateTrigger++;
        }
    }

    Connections {
        target: SettingsData

        function onAppIdSubstitutionsChanged() {
            root._appIdSubstitutionsTrigger++;
        }
    }

    Connections {
        target: SessionData

        function onTrayItemOrderChanged() {
            root._trayOrderTrigger++;
        }
    }

    onAllTrayItemsChanged: root.rescanTrayPids()

    // The scan only feeds the tray->window PID/name hints; tray add/remove
    // already triggers a rescan on its own. A slow heartbeat keeps hints
    // fresh for long-lived trays (Steam respawning helpers etc.) without
    // paying a busctl round-trip set every 30s.
    Timer {
        running: CompositorService.isNiri
        interval: 300000
        repeat: true
        triggeredOnStart: true
        onTriggered: root.rescanTrayPids()
    }

    Process {
        id: trayPidScanner
        running: false
        command: ["python3", root.trayScanScriptPath]
        stdout: StdioCollector {
            onStreamFinished: root.parseTrayScan(text)
        }
    }

    // Running Steam windows are labelled "steam" and have no theme icon, so the
    // dock used to fall back to a plain sports_esports glyph. Reuse Steam's own
    // tray icon so opened and closed Steam look identical.
    QtObject {
        id: steamIconService

        readonly property var candidates: {
            const home = Quickshell.env("HOME") || "";
            if (!home)
                return [];
            return [
                home + "/.local/share/Steam/public/steam_tray_mono.png",
                home + "/.steam/steam/public/steam_tray_mono.png",
                home + "/.local/share/Steam/public/steam_tray.ico",
                home + "/.steam/steam/public/steam_tray.ico"
            ].map(path => "file://" + path);
        }
        property string steamPath: ""
        property int scanIndex: 0

        function scanNext() {
            if (scanIndex >= candidates.length) {
                steamPath = "";
                return;
            }
            steamIconProbe.source = candidates[scanIndex];
        }

        function handleProbe() {
            if (steamIconProbe.status === Image.Ready) {
                steamPath = steamIconProbe.source;
                return;
            }
            scanIndex++;
            scanNext();
        }

        Component.onCompleted: scanNext()
    }

    Image {
        id: steamIconProbe
        visible: false
        cache: true
        asynchronous: false
        onStatusChanged: {
            if (status === Image.Ready || status === Image.Error)
                steamIconService.handleProbe();
        }
    }

    horizontalBarPill: Component {
        Item {
            implicitWidth: row.implicitWidth
            implicitHeight: root.itemSize

            Row {
                id: row
                anchors.centerIn: parent
                spacing: root.itemSpacingSetting

                Loader {
                    active: root.showLauncherButton
                    visible: active
                    sourceComponent: launcherButtonComponent
                }

                Repeater {
                    model: ScriptModel {
                        values: root.displayedItems
                        objectProp: "key"
                    }
                    delegate: unifiedDelegate
                }
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: root.itemSize
            implicitHeight: column.implicitHeight

            Column {
                id: column
                anchors.centerIn: parent
                spacing: root.itemSpacingSetting

                Loader {
                    active: root.showLauncherButton
                    visible: active
                    sourceComponent: launcherButtonComponent
                }

                Repeater {
                    model: ScriptModel {
                        values: root.displayedItems
                        objectProp: "key"
                    }
                    delegate: unifiedDelegate
                }
            }
        }
    }

    Component {
        id: launcherButtonComponent

        Item {
            width: root.isVertical ? root.itemCrossSize : root.iconPixels
            height: root.isVertical ? root.iconPixels : root.itemCrossSize

            Item {
                anchors.centerIn: parent
                width: root.iconPixels
                height: root.iconPixels
                scale: root.enlargeOnHover && launcherMouse.containsMouse ? root.enlargePercentage / 100 : 1

                Behavior on scale {
                    NumberAnimation {
                        duration: Theme.shortDuration
                        easing.type: Easing.OutCubic
                    }
                }

                DIcon {
                    anchors.centerIn: parent
                    name: "apps"
                    size: root.iconPixels
                    color: Theme.widgetTextColor
                }
            }

            MouseArea {
                id: launcherMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: PopoutService.toggleDankLauncherV2()
            }
        }
    }

    Component {
        id: unifiedDelegate

        Item {
            id: delegateRoot

            property var entry: modelData
            readonly property bool isOverflow: entry.kind === "overflow"
            readonly property bool isHiddenRecovery: entry.kind === "hidden"
            readonly property bool isSpecialButton: isOverflow || isHiddenRecovery
            readonly property string barEdge: root.axis?.edge || "top"
            readonly property real dotSize: Math.max(4, Math.round(root.iconPixels * 0.1))
            readonly property int dotCount: {
                if (isSpecialButton || !root.showIndicators)
                    return 0;
                const count = Number(entry.windowCount || 0);
                return count > 0 ? Math.min(4, count) : 0;
            }
            readonly property real hoverScale: root.enlargeOnHover && mouseArea.containsMouse ? root.enlargePercentage / 100 : 1
            // Always draw the icon exactly as the app provides it. Applying the
            // tray tint here is what turned Steam into a flat grey circle that
            // never changed when a window opened.
            readonly property string iconUrl: entry.iconSource || ""
            readonly property bool needsAttention: entry.needsAttention === true
            readonly property bool isPassive: entry.isPassive === true
            // Touchpad wheel accumulation, mirrors RunningApps.
            property real scrollAccumulator: 0
            // Offset applied while this delegate (or a sibling) is being
            // dragged; horizontal bars shift x, vertical bars shift y.
            readonly property real dragShift: {
                const ds = root.dragState;
                if (!ds || !ds.dragging || delegateRoot.isSpecialButton)
                    return 0;
                if (ds.key === entry.key)
                    return ds.visualOffset;
                const bareKey = ds.kind === "tray" ? entry.trayKey : String(entry.pinnedAppId ?? "");
                const myIndex = ds.draggables.indexOf(bareKey);
                if (myIndex < 0)
                    return 0;
                return TrayMenuManager.dragShiftOffset(myIndex, ds.draggedIndex, ds.targetIndex, ds.slotPitch);
            }

            function isDotFocused(dotIndex) {
                if (entry.isFocused !== true)
                    return false;
                if (entry.kind !== "window" && entry.kind !== "tray" && entry.kind !== "pinned")
                    return false;
                const windows = entry.windows || [];
                if (windows.length <= 1)
                    return true;
                const window = windows[dotIndex];
                if (!window)
                    return false;
                return window.activated === true || window.is_focused === true;
            }

            width: root.isVertical ? root.itemCrossSize : root.iconPixels
            height: root.isVertical ? root.iconPixels : root.itemCrossSize
            z: root.dragState?.dragging && root.dragState.key === entry.key ? 10 : 0

            Component.onCompleted: root.registerDelegateItem(delegateRoot)
            // Plugin unload destroys the root before the last delegates;
            // optional-chaining on the root itself keeps teardown quiet.
            Component.onDestruction: root?.unregisterDelegateItem?.(delegateRoot)

            Item {
                id: iconSlot
                anchors.centerIn: parent
                width: root.iconPixels
                height: root.iconPixels
                scale: delegateRoot.isSpecialButton ? 1 : delegateRoot.hoverScale
                // Follows an active drag: the dragged icon glides under the
                // cursor while siblings slide out of the way.
                transform: Translate {
                    x: root.isVertical ? 0 : delegateRoot.dragShift
                    y: root.isVertical ? delegateRoot.dragShift : 0
                }
                // SNI Passive items are registered but idle (no windows);
                // dim them so active work stays visually loud.
                opacity: delegateRoot.isPassive && root.dimPassiveItems && !mouseArea.containsMouse ? 0.55 : 1

                Behavior on scale {
                    NumberAnimation {
                        duration: Theme.shortDuration
                        easing.type: Easing.OutCubic
                    }
                }

                Behavior on opacity {
                    NumberAnimation {
                        duration: Theme.shortDuration
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Theme.primary, mouseArea.containsMouse ? 0.2 : 0.1)
                    visible: delegateRoot.isSpecialButton

                    Behavior on color {
                        ColorAnimation {
                            duration: Theme.shortDuration
                        }
                    }
                }

                DIcon {
                    anchors.centerIn: parent
                    name: delegateRoot.isHiddenRecovery ? "visibility_off" : "expand_more"
                    size: root.iconPixels * 0.6
                    color: Theme.widgetTextColor
                    rotation: delegateRoot.isOverflow && !root.isVertical ? -90 : 0
                    visible: delegateRoot.isSpecialButton
                }

                IconImage {
                    id: iconImg
                    anchors.centerIn: parent
                    implicitSize: root.iconPixels
                    source: delegateRoot.isSpecialButton ? "" : delegateRoot.iconUrl
                    asynchronous: true
                    smooth: true
                    mipmap: true
                    visible: !delegateRoot.isSpecialButton && status === Image.Ready
                }

                DIcon {
                    anchors.centerIn: parent
                    name: "keyboard"
                    size: root.iconPixels
                    color: Theme.widgetTextColor
                    visible: !delegateRoot.isSpecialButton && !iconImg.visible && entry.kind === "input"
                }

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.cornerRadius
                    color: Theme.surfaceLight
                    border.width: 1
                    border.color: Theme.primarySelected
                    visible: !delegateRoot.isSpecialButton && !iconImg.visible && entry.kind !== "input"

                    StyledText {
                        anchors.centerIn: parent
                        text: entry.fallbackText || "?"
                        font.pixelSize: Math.max(8, Math.round(root.iconPixels * 0.4))
                        color: Theme.primary
                        font.weight: Theme.fontWeightMedium
                    }
                }

                // SNI NeedsAttention badge: the tray's standardized
                // "look at me" state, shown as a pulsing dot in the corner.
                Rectangle {
                    id: attentionDot
                    visible: delegateRoot.needsAttention && root.showAttentionDots
                    width: Math.max(6, Math.round(root.iconPixels * 0.24))
                    height: width
                    radius: width / 2
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.rightMargin: -Math.round(width * 0.22)
                    anchors.topMargin: -Math.round(height * 0.22)
                    color: Theme.error
                    border.width: 1
                    border.color: Theme.surface

                    SequentialAnimation on opacity {
                        running: attentionDot.visible
                        loops: Animation.Infinite
                        alwaysRunToEnd: true

                        NumberAnimation {
                            from: 1
                            to: 0.3
                            duration: 900
                            easing.type: Easing.InOutQuad
                        }

                        NumberAnimation {
                            from: 0.3
                            to: 1
                            duration: 900
                            easing.type: Easing.InOutQuad
                        }
                    }
                }
            }

            // Light this icon while one of its windows is focused or running,
            // matching the dock's colorizeActive state layer without hurting
            // the icon's own colours.
            Rectangle {
                anchors.fill: iconSlot
                radius: Theme.cornerRadius
                color: Theme.withAlpha(Theme.primary, Theme.stateLayerPressed)
                visible: !delegateRoot.isSpecialButton && (entry.isFocused === true || delegateRoot.dotCount > 0)
                z: -1
                scale: iconSlot.scale

                Behavior on opacity {
                    NumberAnimation {
                        duration: Theme.shortDuration
                    }
                }
            }

            Item {
                id: indicatorSlot
                visible: delegateRoot.dotCount > 0
                x: root.isVertical ? (delegateRoot.barEdge === "left" ? 0 : parent.width - width) : 0
                y: root.isVertical ? 0 : (delegateRoot.barEdge === "bottom" ? parent.height - height : 0)
                width: root.isVertical ? root.indicatorThickness : parent.width
                height: root.isVertical ? parent.height : root.indicatorThickness

                Row {
                    anchors.centerIn: parent
                    spacing: Theme.spacingXXS
                    visible: !root.isVertical
                    width: implicitWidth

                    Repeater {
                        model: delegateRoot.dotCount

                        Rectangle {
                            readonly property bool focusedDot: delegateRoot.isDotFocused(index)
                            width: focusedDot ? delegateRoot.dotSize * 3 : delegateRoot.dotSize
                            height: delegateRoot.dotSize
                            radius: height / 2
                            color: focusedDot ? Theme.primary : Theme.surfaceTextSecondary

                            Behavior on width {
                                NumberAnimation {
                                    duration: Theme.shortDuration
                                    easing.type: Easing.OutCubic
                                }
                            }

                            Behavior on color {
                                ColorAnimation {
                                    duration: Theme.shortDuration
                                }
                            }
                        }
                    }
                }

                Column {
                    anchors.centerIn: parent
                    spacing: Theme.spacingXXS
                    visible: root.isVertical
                    height: implicitHeight

                    Repeater {
                        model: delegateRoot.dotCount

                        Rectangle {
                            readonly property bool focusedDot: delegateRoot.isDotFocused(index)
                            width: delegateRoot.dotSize
                            height: focusedDot ? delegateRoot.dotSize * 3 : delegateRoot.dotSize
                            radius: width / 2
                            color: focusedDot ? Theme.primary : Theme.surfaceTextSecondary

                            Behavior on height {
                                NumberAnimation {
                                    duration: Theme.shortDuration
                                    easing.type: Easing.OutCubic
                                }
                            }

                            Behavior on color {
                                ColorAnimation {
                                    duration: Theme.shortDuration
                                }
                            }
                        }
                    }
                }
            }

            MouseArea {
                id: mouseArea
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                cursorShape: Qt.PointingHandCursor

                onPressed: mouse => {
                    // Start tracking a potential reordering drag for tray and
                    // pinned icons (windows keep compositor order).
                    if (mouse.button === Qt.LeftButton)
                        root.beginDrag(entry, mouse.x, mouse.y);
                }

                onPositionChanged: mouse => {
                    if (root.dragState)
                        root.updateDrag(mouse.x, mouse.y);
                }

                onReleased: mouse => {
                    if (mouse.button === Qt.LeftButton && root.dragState) {
                        // Swallow the click that follows a completed drag so
                        // dropping an icon doesn't also "activate" it.
                        if (root.finishDrag())
                            root._suppressClickUntil = Date.now() + 150;
                    }
                }

                onClicked: mouse => {
                    if (mouse.button !== Qt.MiddleButton && Date.now() < root._suppressClickUntil)
                        return;
                    if (mouse.button === Qt.LeftButton) {
                        if (entry.kind === "overflow")
                            root.openOverflowMenu(entry, mouseArea, mouse, delegateRoot);
                        else if (entry.kind === "hidden")
                            root.openHiddenItemsMenu(entry, mouseArea, mouse, delegateRoot);
                        else if (entry.trayItem?.onlyMenu && entry.kind === "tray")
                            // Menu-only tray items (no Activate()): left click
                            // opens the menu, like the built-in tray.
                            root.openContextMenu(entry, mouseArea, mouse, delegateRoot);
                        else
                            root.activateUnifiedItem(entry);
                    } else if (mouse.button === Qt.RightButton) {
                        if (entry.kind === "overflow")
                            root.openOverflowMenu(entry, mouseArea, mouse, delegateRoot);
                        else if (entry.kind === "hidden")
                            root.openHiddenItemsMenu(entry, mouseArea, mouse, delegateRoot);
                        else
                            root.openContextMenu(entry, mouseArea, mouse, delegateRoot);
                    } else if (mouse.button === Qt.MiddleButton) {
                        root.middleClickUnifiedItem(entry);
                    }
                }

                onWheel: wheel => {
                    // Scroll cycles this entry's windows (mouse wheel steps
                    // once; touchpad input accumulates like RunningApps).
                    wheel.accepted = true;
                    const windows = entry.windows || [];
                    if (windows.length < 2)
                        return;
                    const deltaY = wheel.angleDelta.y;
                    const isMouseWheel = Math.abs(deltaY) >= 120 && (Math.abs(deltaY) % 120) === 0;
                    if (isMouseWheel) {
                        root.stepWindowGroup(windows, deltaY);
                        delegateRoot.scrollAccumulator = 0;
                        return;
                    }
                    delegateRoot.scrollAccumulator += deltaY;
                    if (Math.abs(delegateRoot.scrollAccumulator) >= 500) {
                        root.stepWindowGroup(windows, delegateRoot.scrollAccumulator);
                        delegateRoot.scrollAccumulator = 0;
                    }
                }

                onEntered: {
                    root.hoveredItem = delegateRoot;
                    root.showTooltip(delegateRoot, entry.tooltipText || "");
                }

                onExited: {
                    if (root.hoveredItem === delegateRoot) {
                        root.hoveredItem = null;
                        root.hideTooltip();
                    }
                }
            }
        }
    }

    // ---- Drag-to-reorder --------------------------------------------------
    // Tray items persist into SessionData.trayItemOrder (the same store the
    // built-in SystemTrayBar uses, so order is shared), pinned items into
    // SessionData.barPinnedApps. Windows are not draggable: their order is
    // compositor/workspace order.

    function draggableKind(entry) {
        if (!entry)
            return "";
        if (entry.kind === "tray" || entry.kind === "input")
            return "tray";
        if (entry.kind === "pinned")
            return "pinned";
        return "";
    }

    function draggablesFor(kind) {
        const out = [];
        const items = root.displayedItems || [];
        for (let i = 0; i < items.length; i++) {
            const item = items[i];
            if (draggableKind(item) !== kind)
                continue;
            out.push(kind === "tray" ? item.trayKey : String(item.pinnedAppId ?? ""));
        }
        return out;
    }

    function beginDrag(entry, pressX, pressY) {
        if (root.dragState)
            return;
        const kind = draggableKind(entry);
        if (!kind)
            return;
        const draggables = draggablesFor(kind);
        const bareKey = kind === "tray" ? entry.trayKey : String(entry.pinnedAppId ?? "");
        const draggedIndex = draggables.indexOf(bareKey);
        if (draggedIndex < 0)
            return;
        root.hideTooltip();
        const itemExtent = root.isVertical ? root.itemCrossSize : root.iconPixels;
        root.dragState = {
            "kind": kind,
            "key": entry.key,
            "draggables": draggables,
            "draggedIndex": draggedIndex,
            "targetIndex": draggedIndex,
            "pressX": pressX,
            "pressY": pressY,
            "dragging": false,
            "visualOffset": 0,
            "slotPitch": itemExtent + root.itemSpacingSetting,
            "vertical": !!root.isVertical
        };
    }

    function updateDrag(posX, posY) {
        const ds = root.dragState;
        if (!ds)
            return;
        const delta = (ds.vertical ? posY - ds.pressY : posX - ds.pressX) || 0;
        if (!ds.dragging && Math.abs(delta) < 10)
            return;
        const slot = Math.round(delta / ds.slotPitch);
        const target = Math.max(0, Math.min(ds.draggables.length - 1, ds.draggedIndex + slot));
        // Replace the object (not mutate) so bindings on dragState refresh.
        root.dragState = Object.assign({}, ds, {
            "dragging": true,
            "visualOffset": delta,
            "targetIndex": target
        });
    }

    function finishDrag() {
        const ds = root.dragState;
        root.dragState = null;
        if (!ds || !ds.dragging)
            return false;
        if (ds.targetIndex === ds.draggedIndex)
            return true;
        const fromKey = ds.draggables[ds.draggedIndex];
        const toKey = ds.draggables[ds.targetIndex];
        if (!fromKey || !toKey || fromKey === toKey)
            return true;
        if (ds.kind === "tray") {
            const allKeys = (root.sortedTrayItems || []).map(item => root.trayDisplayKey(item));
            const nextOrder = TrayMenuManager.reorderItemKeys(allKeys, fromKey, toKey);
            if (nextOrder)
                SessionData.setTrayItemOrder(nextOrder);
        } else if (ds.kind === "pinned") {
            const pinned = [...(SessionData.barPinnedApps || [])];
            const fromIdx = pinned.indexOf(fromKey);
            const toIdx = pinned.indexOf(toKey);
            if (fromIdx >= 0 && toIdx >= 0 && fromIdx !== toIdx) {
                const moved = pinned.splice(fromIdx, 1)[0];
                pinned.splice(toIdx, 0, moved);
                SessionData.setBarPinnedApps(pinned);
            }
        }
        return true;
    }

    Loader {
        id: tooltipLoader
        active: false
        sourceComponent: DankTooltip {}
    }

    // Millisecond timestamp; a click landing within this window right after
    // a finished drag is swallowed so dropping doesn't also activate.
    property real _suppressClickUntil: 0

    function registerDelegateItem(item) {
        if (!item || root.delegateItems.indexOf(item) !== -1)
            return;
        root.delegateItems = [...root.delegateItems, item];
    }

    function unregisterDelegateItem(item) {
        if (!item)
            return;
        root.delegateItems = root.delegateItems.filter(candidate => candidate !== item);
    }

    function delegateItemAt(screenX, screenY) {
        const screenOriginX = root.parentScreen?.x ?? 0;
        const screenOriginY = root.parentScreen?.y ?? 0;
        const items = root.delegateItems || [];
        for (let i = items.length - 1; i >= 0; i--) {
            const item = items[i];
            if (!item || !item.visible || !item.entry)
                continue;
            const globalPos = item.mapToGlobal(0, 0);
            const left = globalPos.x - screenOriginX;
            const top = globalPos.y - screenOriginY;
            if (screenX >= left && screenX <= left + item.width && screenY >= top && screenY <= top + item.height)
                return item;
        }
        return null;
    }

    function switchMenuAt(screenX, screenY) {
        const targetItem = root.delegateItemAt(screenX, screenY);
        if (!targetItem)
            return false;

        const entry = targetItem.entry;
        const contextMenu = windowContextMenuLoader.item;
        if (contextMenu?.isVisible && contextMenu.currentEntry?.key === entry?.key) {
            contextMenu.close();
            return true;
        }

        if (contextMenu?.isVisible && entry?.kind !== "overflow" && entry?.kind !== "hidden") {
            root.openContextMenu(entry, targetItem, null, targetItem);
            return true;
        }

        if (contextMenu?.isVisible)
            contextMenu.close();
        if (overflowMenuLoader.item?.isVisible)
            overflowMenuLoader.item.close();

        Qt.callLater(() => {
            if (entry?.kind === "overflow")
                root.openOverflowMenu(entry, targetItem, null, targetItem);
            else if (entry?.kind === "hidden")
                root.openHiddenItemsMenu(entry, targetItem, null, targetItem);
            else
                root.openContextMenu(entry, targetItem, null, targetItem);
        });
        return true;
    }

    function isDesktopIdPinned(desktopId) {
        if (!desktopId)
            return false;
        const pinned = SessionData.barPinnedApps || [];
        return pinned.some(id => norm(id) === norm(desktopId) || norm(id) === norm(Paths.moddedAppId(String(desktopId))));
    }

    // App-specific actions are rendered by TrayMenuContent inside the same
    // popup. These are the dock-style footer actions shown below them.
    function contextActionsFor(entry) {
        return entry ? root.footerActionsFor(entry) : [];
    }

    function footerActionsFor(entry) {
        const actions = [];
        if (root.newWindowActionForEntry(entry)) {
            actions.push({
                "action": "newWindow",
                "icon": "open_in_new",
                "label": I18n.tr("新建窗口")
            });
        }
        const canonical = root.canonicalPinnedIdForEntry(entry);
        if (canonical) {
            const pinned = root.isEntryPinned(entry);
            actions.push({
                "action": "pin",
                "icon": pinned ? "keep_off" : "push_pin",
                "label": pinned ? I18n.tr("取消固定") : I18n.tr("固定到托盘")
            });
        }
        if ((entry.windows?.length ?? 0) > 0) {
            actions.push({
                "action": "close",
                "icon": "close",
                "label": entry.windows.length > 1 ? I18n.tr("关闭全部 %1 个窗口").arg(entry.windows.length) : I18n.tr("关闭窗口"),
                "destructive": true
            });
        }
        return actions;
    }

    // Right-click menu modelled on the built-in dock: window rows with
    // minimise/close buttons, then pin, then close, all in one level.
    Loader {
        id: windowContextMenuLoader
        active: false
        sourceComponent: PanelWindow {
            id: contextMenuWindow

            property var currentEntry: null
            property var currentAnchorItem: null
            property bool isVisible: false
            property point anchorPos: Qt.point(0, 0)
            property bool isVertical: false
            property string edge: "top"
            property real triggerBarThickness: 0
            property real triggerBarSpacing: 0

            readonly property var entryWindows: currentEntry?.windows || []
            readonly property bool entryPinned: root.isEntryPinned(currentEntry)
            readonly property bool canPin: !!root.canonicalPinnedIdForEntry(currentEntry)
            readonly property bool hasTrayItem: !!currentEntry?.trayItem
            readonly property var trayMenuHandle: currentEntry?.trayItem?.menu ?? null
            readonly property var actions: root.contextActionsFor(currentEntry)
            readonly property int menuHeight: Math.max(34, menuColumn.implicitHeight + Theme.spacingS * 2)

            Timer {
                id: trayActionCloseTimer
                interval: 80
                repeat: false
                onTriggered: contextMenuWindow.close()
            }

            function showAt(x, y, vertical, barEdge) {
                screen = root.parentScreen;
                anchorPos = Qt.point(x, y);
                isVertical = vertical ?? false;
                edge = barEdge ?? "top";
                nativeTrayMenu.clearState();
                const handle = trayMenuHandle;
                if (handle && typeof handle.updateLayout === "function")
                    handle.updateLayout();
                isVisible = true;
                visible = true;

                if (screen) {
                    TrayMenuManager.registerMenu(screen.name, contextMenuWindow);
                }
            }

            function close() {
                nativeTrayMenu.clearState();
                isVisible = false;
                visible = false;
                windowContextMenuLoader.active = false;

                if (screen) {
                    TrayMenuManager.unregisterMenu(screen.name);
                }
            }

            implicitWidth: 100
            implicitHeight: 40
            visible: false
            color: "transparent"

            WlrLayershell.layer: WlrLayershell.Overlay
            WlrLayershell.exclusiveZone: -1
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            anchors {
                top: true
                left: true
                right: true
                bottom: true
            }

            Component.onDestruction: {
                if (screen) {
                    TrayMenuManager.unregisterMenu(screen.name);
                }
            }

            Connections {
                target: PopoutManager
                function onPopoutOpening() {
                    contextMenuWindow.close();
                }
            }

            WindowBlur {
                targetWindow: contextMenuWindow
                surfaceColor: contextMenuRect.color
                blurX: contextMenuRect.x
                blurY: contextMenuRect.y
                blurWidth: contextMenuWindow.isVisible ? contextMenuRect.width : 0
                blurHeight: contextMenuWindow.isVisible ? contextMenuRect.height : 0
                blurRadius: Theme.windowRadius
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: mouse => {
                    if (mouse.button === Qt.RightButton && root.switchMenuAt(mouse.x, mouse.y))
                        return;
                    contextMenuWindow.close();
                }
            }

            Rectangle {
                id: contextMenuRect

                x: {
                    if (contextMenuWindow.isVertical) {
                        if (contextMenuWindow.edge === "left")
                            return Math.min(contextMenuWindow.width - width - 10, contextMenuWindow.anchorPos.x);
                        return Math.max(10, contextMenuWindow.anchorPos.x - width);
                    }
                    const left = 10;
                    const right = contextMenuWindow.width - width - 10;
                    const want = contextMenuWindow.anchorPos.x - width / 2;
                    return Math.max(left, Math.min(right, want));
                }
                y: {
                    if (contextMenuWindow.isVertical) {
                        const top = 10;
                        const bottom = contextMenuWindow.height - height - 10;
                        const want = contextMenuWindow.anchorPos.y - height / 2;
                        return Math.max(top, Math.min(bottom, want));
                    }
                    if (contextMenuWindow.edge === "bottom")
                        return Math.max(10, contextMenuWindow.anchorPos.y - height);
                    return contextMenuWindow.anchorPos.y;
                }
                width: Math.min(360, Math.max(200, menuColumn.implicitWidth + Theme.spacingS * 2))
                height: Math.max(34, menuColumn.implicitHeight + Theme.spacingS * 2)
                color: Theme.floatingSurface
                radius: Theme.windowRadius
                border.width: BlurService.borderWidth
                border.color: BlurService.borderColor
                opacity: contextMenuWindow.isVisible ? 1 : 0
                visible: opacity > 0

                Behavior on opacity {
                    NumberAnimation {
                        duration: Theme.shortDuration
                        easing.type: Theme.emphasizedEasing
                    }
                }

                Column {
                    id: menuColumn
                    width: parent.width - Theme.spacingS * 2
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    anchors.topMargin: Theme.spacingS
                    spacing: 1

                    Repeater {
                        model: contextMenuWindow.entryWindows

                        Rectangle {
                            id: windowRow

                            required property var modelData

                            readonly property bool rowHovered: windowArea.containsMouse || minimizeField.containsMouse || closeField.containsMouse

                            width: menuColumn.width
                            height: 28
                            radius: Theme.cornerRadius
                            color: rowHovered ? BlurService.hoverColor(Theme.widgetBaseHoverColor) : "transparent"

                            StyledText {
                                id: windowTitleText
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.spacingS
                                anchors.right: windowButtons.left
                                anchors.rightMargin: Theme.spacingXS
                                anchors.verticalCenter: parent.verticalCenter
                                text: windowRow.modelData?.title || I18n.tr("新窗口")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                                font.weight: Theme.fontWeight
                                elide: Text.ElideRight
                                wrapMode: Text.NoWrap
                            }

                            Row {
                                id: windowButtons
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.spacingXS
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2

                                Rectangle {
                                    width: 20
                                    height: 20
                                    radius: Theme.cornerRadiusS
                                    color: minimizeField.containsMouse ? BlurService.hoverColor(Theme.widgetBaseHoverColor) : "transparent"

                                    DIcon {
                                        anchors.centerIn: parent
                                        name: windowRow.modelData?.minimized ? "expand_content" : "minimize"
                                        size: 12
                                        color: Theme.surfaceText
                                    }

                                    MouseArea {
                                        id: minimizeField
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            const target = windowRow.modelData;
                                            if (!target)
                                                return;
                                            if (target.minimized)
                                                CompositorService.activateToplevel(target);
                                            else
                                                target.minimized = true;
                                            contextMenuWindow.close();
                                        }
                                    }
                                }

                                Rectangle {
                                    width: 20
                                    height: 20
                                    radius: Theme.cornerRadiusS
                                    color: closeField.containsMouse ? Theme.errorPressed : "transparent"

                                    DIcon {
                                        anchors.centerIn: parent
                                        name: "close"
                                        size: 12
                                        color: closeField.containsMouse ? Theme.error : Theme.surfaceText
                                    }

                                    MouseArea {
                                        id: closeField
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            windowRow.modelData?.close();
                                            contextMenuWindow.close();
                                        }
                                    }
                                }
                            }

                            MouseArea {
                                id: windowArea
                                anchors.fill: parent
                                anchors.rightMargin: windowButtons.width + Theme.spacingXS
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    const target = windowRow.modelData;
                                    if (target) {
                                        CompositorService.activateToplevel(target);
                                        target.activate?.();
                                    }
                                    contextMenuWindow.close();
                                }
                            }
                        }
                    }

                    Rectangle {
                        visible: contextMenuWindow.entryWindows.length > 0 && (contextMenuWindow.hasTrayItem || contextMenuWindow.actions.length > 0)
                        width: parent.width
                        height: 1
                        color: Theme.outlineHeavy
                    }

                    DBarWidgets.TrayMenuContent {
                        id: nativeTrayMenu
                        visible: contextMenuWindow.hasTrayItem
                        width: parent.width
                        height: visible ? implicitHeight : 0
                        trayItem: contextMenuWindow.currentEntry?.trayItem ?? null
                        menuHandle: contextMenuWindow.trayMenuHandle
                        anchorWindow: contextMenuWindow
                        bar: null
                        onCloseRequested: contextMenuWindow.close()
                        onActionTriggered: trayActionCloseTimer.restart()
                    }

                    Rectangle {
                        visible: contextMenuWindow.hasTrayItem && contextMenuWindow.actions.length > 0
                        width: parent.width
                        height: 1
                        color: Theme.outlineHeavy
                    }

                    Repeater {
                        model: contextMenuWindow.actions

                        Rectangle {
                            id: actionRow

                            required property var modelData

                            width: parent.width
                            height: 28
                            radius: Theme.cornerRadius
                            color: {
                                if (!actionField.containsMouse)
                                    return "transparent";
                                return modelData.destructive ? Theme.errorHover : BlurService.hoverColor(Theme.widgetBaseHoverColor);
                            }

                            Row {
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.spacingS
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingXS

                                DIcon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: actionRow.modelData.icon || ""
                                    size: 14
                                    color: actionRow.modelData.destructive && actionField.containsMouse ? Theme.error : Theme.surfaceText
                                    opacity: 0.7
                                }

                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: actionRow.modelData.label || ""
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: actionRow.modelData.destructive && actionField.containsMouse ? Theme.error : Theme.surfaceText
                                    font.weight: Theme.fontWeight
                                    elide: Text.ElideRight
                                    wrapMode: Text.NoWrap
                                }
                            }

                            MouseArea {
                                id: actionField
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    const action = actionRow.modelData.action;
                                    const entry = contextMenuWindow.currentEntry;
                                    const anchor = contextMenuWindow.currentAnchorItem;
                                    contextMenuWindow.close();
                                    if (action === "newWindow") {
                                        root.launchNewWindow(entry);
                                    } else if (action === "pin") {
                                        root.togglePinEntry(entry);
                                    } else if (action === "close") {
                                        const targets = (entry?.windows || []).slice();
                                        for (let i = 0; i < targets.length; i++)
                                            targets[i]?.close();
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Loader {
        id: overflowMenuLoader
        active: false
        sourceComponent: PanelWindow {
            id: overflowWindow

            property var entries: []
            property bool isVisible: false
            property point anchorPos: Qt.point(0, 0)
            property bool isVertical: false
            property string edge: "top"
            property bool restoreHiddenItems: false

            function showFor(items, x, y, vertical, barEdge, restoreMode) {
                entries = items;
                anchorPos = Qt.point(x, y);
                isVertical = vertical ?? false;
                edge = barEdge ?? "top";
                restoreHiddenItems = restoreMode === true;
                isVisible = true;
                visible = true;
                screen = root.parentScreen;

                if (screen)
                    TrayMenuManager.registerMenu(screen.name, overflowWindow);
            }

            function close() {
                isVisible = false;
                visible = false;
                overflowMenuLoader.active = false;

                if (screen)
                    TrayMenuManager.unregisterMenu(screen.name);
            }

            implicitWidth: 100
            implicitHeight: 40
            visible: false
            color: "transparent"

            WlrLayershell.layer: WlrLayershell.Overlay
            WlrLayershell.exclusiveZone: -1
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            anchors {
                top: true
                left: true
                right: true
                bottom: true
            }

            Component.onDestruction: {
                if (screen)
                    TrayMenuManager.unregisterMenu(screen.name);
            }

            Connections {
                target: PopoutManager
                function onPopoutOpening() {
                    overflowWindow.close();
                }
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: mouse => {
                    if (mouse.button === Qt.RightButton && root.switchMenuAt(mouse.x, mouse.y))
                        return;
                    overflowWindow.close();
                }
            }

            Rectangle {
                id: overflowRect
                readonly property int rowHeight: 38
                readonly property int maxRows: 9
                readonly property int rows: Math.min(overflowWindow.entries.length, maxRows)
                x: {
                    if (overflowWindow.isVertical) {
                        if (overflowWindow.edge === "left")
                            return Math.min(overflowWindow.width - width - 10, overflowWindow.anchorPos.x);
                        return Math.max(10, overflowWindow.anchorPos.x - width);
                    }
                    const left = 10;
                    const right = overflowWindow.width - width - 10;
                    const want = overflowWindow.anchorPos.x - width / 2;
                    return Math.max(left, Math.min(right, want));
                }
                y: {
                    if (overflowWindow.isVertical) {
                        const top = 10;
                        const bottom = overflowWindow.height - height - 10;
                        const want = overflowWindow.anchorPos.y - height / 2;
                        return Math.max(top, Math.min(bottom, want));
                    }
                    return overflowWindow.anchorPos.y;
                }
                width: 240
                height: Math.max(rowHeight, rows * rowHeight + 8)
                color: Theme.withAlpha(Theme.surfaceContainer, Theme.popupTransparency)
                radius: Theme.cornerRadius
                border.width: BlurService.enabled ? BlurService.borderWidth : 1
                border.color: BlurService.enabled ? BlurService.borderColor : Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.12)

                Flickable {
                    anchors.fill: parent
                    anchors.margins: 4
                    contentHeight: overflowColumn.height
                    clip: true

                    Column {
                        id: overflowColumn
                        width: parent.width
                        spacing: 2

                        Repeater {
                            model: overflowWindow.entries

                            delegate: Rectangle {
                                id: overflowRow
                                required property var modelData
                                width: overflowColumn.width
                                height: overflowRect.rowHeight
                                radius: Math.max(2, Theme.cornerRadius - 2)
                                color: overflowRowMouse.containsMouse ? BlurService.hoverColor(Theme.widgetBaseHoverColor) : "transparent"

                                Row {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.leftMargin: Theme.spacingS
                                    anchors.rightMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spacingS

                                    Image {
                                        id: overflowIcon
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 22
                                        height: 22
                                        source: modelData.iconSource || ""
                                        asynchronous: true
                                        visible: status === Image.Ready
                                    }

                                    DIcon {
                                        anchors.verticalCenter: parent.verticalCenter
                                        name: "apps"
                                        size: 22
                                        color: Theme.widgetTextColor
                                        visible: !overflowIcon.visible
                                    }

                                    StyledText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - 70
                                        text: modelData.tooltipText || modelData.appId || ""
                                        elide: Text.ElideRight
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.widgetTextColor
                                    }
                                }

                                MouseArea {
                                    id: overflowRowMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        const entry = modelData;
                                        if (overflowWindow.restoreHiddenItems) {
                                            const itemKey = root.getTrayItemKey(entry?.trayItem);
                                            overflowWindow.close();
                                            if (itemKey)
                                                SessionData.showTrayId(itemKey);
                                            return;
                                        }
                                        overflowWindow.close();
                                        root.activateUnifiedItem(entry);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Component {
        id: trayMenuComponent

        Rectangle {
            id: menuRoot

            property var trayItem: null
            property var anchorItem: null
            property var parentScreen: null
            property bool isAtBottom: false
            property bool isVertical: false
            property var axis: null
            property bool showMenu: false
            property var menuHandle: null

            ListModel {
                id: entryStack
            }

            Timer {
                id: pendingActionCloseTimer
                interval: 80
                repeat: false
                onTriggered: menuRoot.closeWithAction()
            }

            function topEntry() {
                return entryStack.count ? entryStack.get(entryStack.count - 1).handle : null;
            }

            function showForTrayItem(item, anchor, screen, atBottom, vertical, axisObj) {
                trayItem = item;
                anchorItem = anchor;
                parentScreen = screen;
                isAtBottom = atBottom;
                isVertical = vertical;
                axis = axisObj;
                menuHandle = item?.menu;

                if (parentScreen) {
                    for (var i = 0; i < Quickshell.screens.length; i++) {
                        const s = Quickshell.screens[i];
                        if (s === parentScreen) {
                            menuWindow.screen = s;
                            break;
                        }
                    }
                }

                showMenu = true;
            }

            function close() {
                showMenu = false;
            }

            Connections {
                target: menuWindow
                function onVisibleChanged() {
                    if (menuWindow.visible && parentScreen) {
                        TrayMenuManager.registerMenu(parentScreen.name, menuRoot);
                    } else if (!menuWindow.visible && parentScreen) {
                        TrayMenuManager.unregisterMenu(parentScreen.name);
                    }
                }
            }

            Component.onDestruction: {
                if (parentScreen) {
                    TrayMenuManager.unregisterMenu(parentScreen.name);
                }
            }

            Connections {
                target: PopoutManager
                function onPopoutOpening() {
                    menuRoot.close();
                }
            }

            function closeWithAction() {
                close();
            }

            function showSubMenu(entry) {
                if (!entry || !entry.hasChildren)
                    return;

                entryStack.append({
                    handle: entry
                });

                const h = entry.menu || entry;
                if (h && typeof h.updateLayout === "function")
                    h.updateLayout();

                submenuHydrator.menu = h;
                submenuHydrator.open();
                Qt.callLater(() => submenuHydrator.close());
            }

            function goBack() {
                if (!entryStack.count)
                    return;
                entryStack.remove(entryStack.count - 1);
            }

            width: 0
            height: 0
            color: "transparent"

            PanelWindow {
                id: menuWindow

                WindowBlur {
                    targetWindow: menuWindow
                    blurX: trayMenuContainer.x
                    blurY: trayMenuContainer.y
                    blurWidth: menuRoot.showMenu ? trayMenuContainer.width : 0
                    blurHeight: menuRoot.showMenu ? trayMenuContainer.height : 0
                    blurRadius: Theme.cornerRadius
                }

                WlrLayershell.namespace: "dms:tray-menu-window"
                visible: menuRoot.showMenu && (menuRoot.trayItem?.hasMenu ?? false)
                WlrLayershell.layer: WlrLayershell.Top
                WlrLayershell.exclusiveZone: -1
                WlrLayershell.keyboardFocus: {
                    if (!menuRoot.showMenu)
                        return WlrKeyboardFocus.None;
                    if (CompositorService.useHyprlandFocusGrab)
                        return WlrKeyboardFocus.OnDemand;
                    return WlrKeyboardFocus.Exclusive;
                }
                color: "transparent"

                HyprlandFocusGrab {
                    windows: [menuWindow]
                    active: CompositorService.useHyprlandFocusGrab && menuRoot.showMenu
                }

                anchors {
                    top: true
                    left: true
                    right: true
                    bottom: true
                }

                readonly property real dpr: (typeof CompositorService !== "undefined" && CompositorService.getScreenScale) ? CompositorService.getScreenScale(menuWindow.screen) : (screen?.devicePixelRatio || 1)
                property point anchorPos: Qt.point(screen.width / 2, screen.height / 2)

                property var barBounds: {
                    if (!menuWindow.screen || !root.barConfig) {
                        return {
                            "x": 0,
                            "y": 0,
                            "width": 0,
                            "height": 0,
                            "wingSize": 0
                        };
                    }
                    const barPosition = root.axis?.edge === "left" ? 2 : (root.axis?.edge === "right" ? 3 : (root.axis?.edge === "top" ? 0 : 1));
                    return SettingsData.getBarBounds(menuWindow.screen, root.barThickness + root.barSpacing, barPosition, root.barConfig);
                }

                property real barX: barBounds.x
                property real barY: barBounds.y
                property real barWidth: barBounds.width
                property real barHeight: barBounds.height

                readonly property int barPosition: root.axis?.edge === "left" ? 2 : (root.axis?.edge === "right" ? 3 : (root.axis?.edge === "top" ? 0 : 1))
                readonly property var adjacentBarInfo: menuRoot.parentScreen ? SettingsData.getAdjacentBarInfo(menuRoot.parentScreen, barPosition, root.barConfig) : ({
                        "topBar": 0,
                        "bottomBar": 0,
                        "leftBar": 0,
                        "rightBar": 0
                    })
                readonly property real effectiveBarSize: root.barThickness + root.barSpacing

                readonly property real maskX: {
                    const triggeringBarX = (barPosition === 2) ? effectiveBarSize : 0;
                    const adjacentLeftBar = adjacentBarInfo?.leftBar ?? 0;
                    return Math.max(triggeringBarX, adjacentLeftBar);
                }

                readonly property real maskY: {
                    const triggeringBarY = (barPosition === 0) ? effectiveBarSize : 0;
                    const adjacentTopBar = adjacentBarInfo?.topBar ?? 0;
                    return Math.max(triggeringBarY, adjacentTopBar);
                }

                readonly property real maskWidth: {
                    const triggeringBarRight = (barPosition === 3) ? effectiveBarSize : 0;
                    const adjacentRightBar = adjacentBarInfo?.rightBar ?? 0;
                    const rightExclusion = Math.max(triggeringBarRight, adjacentRightBar);
                    return Math.max(100, width - maskX - rightExclusion);
                }

                readonly property real maskHeight: {
                    const triggeringBarBottom = (barPosition === 1) ? effectiveBarSize : 0;
                    const adjacentBottomBar = adjacentBarInfo?.bottomBar ?? 0;
                    const bottomExclusion = Math.max(triggeringBarBottom, adjacentBottomBar);
                    return Math.max(100, height - maskY - bottomExclusion);
                }

                mask: Region {
                    item: Rectangle {
                        x: menuWindow.maskX
                        y: menuWindow.maskY
                        width: menuWindow.maskWidth
                        height: menuWindow.maskHeight
                    }
                }

                onVisibleChanged: {
                    if (visible) {
                        updatePosition();
                        root.menuOpen = false;
                        PopoutManager.closeAllPopouts();
                        ModalManager.closeAllModalsExcept(null);
                    }
                }

                MouseArea {
                    x: menuWindow.maskX
                    y: menuWindow.maskY
                    width: menuWindow.maskWidth
                    height: menuWindow.maskHeight
                    z: -1
                    enabled: menuRoot.showMenu
                    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                    onClicked: mouse => {
                        const clickX = mouse.x + menuWindow.maskX;
                        const clickY = mouse.y + menuWindow.maskY;
                        const outsideContent = clickX < trayMenuContainer.x || clickX > trayMenuContainer.x + trayMenuContainer.width || clickY < trayMenuContainer.y || clickY > trayMenuContainer.y + trayMenuContainer.height;

                        if (!outsideContent)
                            return;
                        menuRoot.close();
                    }
                }

                FocusScope {
                    id: menuFocusScope
                    anchors.fill: parent
                    focus: true

                    Keys.onEscapePressed: {
                        if (entryStack.count > 0) {
                            menuRoot.goBack();
                        } else {
                            menuRoot.close();
                        }
                    }
                }

                function updatePosition() {
                    const targetItem = (typeof menuRoot !== "undefined" && menuRoot.anchorItem) ? menuRoot.anchorItem : root;

                    const isFromOverflowMenu = targetItem.objectName === "overflowMenuContainer";

                    if (isFromOverflowMenu) {
                        if (menuRoot.isVertical) {
                            const edge = menuRoot.axis?.edge;
                            let targetX = edge === "left" ? root.barThickness + root.barSpacing + Theme.popupDistance : screen.width - (root.barThickness + root.barSpacing + Theme.popupDistance);
                            const targetY = targetItem.y + targetItem.height / 2;
                            anchorPos = Qt.point(targetX, targetY);
                        } else {
                            const targetX = targetItem.x + targetItem.width / 2;
                            let targetY = menuRoot.isAtBottom ? screen.height - (root.barThickness + root.barSpacing + (barConfig?.bottomGap ?? 0) + Theme.popupDistance) : root.barThickness + root.barSpacing + (barConfig?.bottomGap ?? 0) + Theme.popupDistance;
                            anchorPos = Qt.point(targetX, targetY);
                        }
                    } else {
                        const globalPos = targetItem.mapToGlobal(0, 0);
                        const screenX = screen.x || 0;
                        const screenY = screen.y || 0;
                        const relativeX = globalPos.x - screenX;
                        const relativeY = globalPos.y - screenY;

                        if (menuRoot.isVertical) {
                            const edge = menuRoot.axis?.edge;
                            let targetX = edge === "left" ? root.barThickness + root.barSpacing + Theme.popupDistance : screen.width - (root.barThickness + root.barSpacing + Theme.popupDistance);
                            const adjustedY = relativeY + targetItem.height / 2 + root.minTooltipY;
                            anchorPos = Qt.point(targetX, adjustedY);
                        } else {
                            let targetY = menuRoot.isAtBottom ? screen.height - (root.barThickness + root.barSpacing + (barConfig?.bottomGap ?? 0) + Theme.popupDistance) : root.barThickness + root.barSpacing + (barConfig?.bottomGap ?? 0) + Theme.popupDistance;
                            anchorPos = Qt.point(relativeX + targetItem.width / 2, targetY);
                        }
                    }
                }

                Item {
                    id: trayMenuContainer

                    readonly property real rawWidth: Math.min(500, Math.max(250, menuColumn.implicitWidth + Theme.spacingS * 2))
                    readonly property real rawHeight: Math.max(40, menuColumn.implicitHeight + Theme.spacingS * 2)

                    readonly property real alignedWidth: Theme.px(rawWidth, menuWindow.dpr)
                    readonly property real alignedHeight: Theme.px(rawHeight, menuWindow.dpr)

                    width: alignedWidth
                    height: alignedHeight

                    x: Theme.snap((() => {
                            if (menuRoot.isVertical) {
                                const edge = menuRoot.axis?.edge;
                                if (edge === "left") {
                                    const targetX = menuWindow.anchorPos.x;
                                    return Math.min(menuWindow.screen.width - alignedWidth - 10, targetX);
                                } else {
                                    const targetX = menuWindow.anchorPos.x - alignedWidth;
                                    return Math.max(10, targetX);
                                }
                            } else {
                                const left = 10;
                                const right = menuWindow.width - alignedWidth - 10;
                                const want = menuWindow.anchorPos.x - alignedWidth / 2;
                                return Math.max(left, Math.min(right, want));
                            }
                        })(), menuWindow.dpr)

                    y: Theme.snap((() => {
                            if (menuRoot.isVertical) {
                                const top = Math.max(menuWindow.barY, 10);
                                const bottom = menuWindow.height - alignedHeight - 10;
                                const want = menuWindow.anchorPos.y - alignedHeight / 2;
                                return Math.max(top, Math.min(bottom, want));
                            } else {
                                if (menuRoot.isAtBottom) {
                                    const targetY = menuWindow.anchorPos.y - alignedHeight;
                                    return Math.max(10, targetY);
                                } else {
                                    const targetY = menuWindow.anchorPos.y;
                                    return Math.min(menuWindow.screen.height - alignedHeight - 10, targetY);
                                }
                            }
                        })(), menuWindow.dpr)

                    property real shadowBlurPx: 10
                    property real shadowSpreadPx: 0
                    property real shadowBaseAlpha: 0.60
                    readonly property real popupSurfaceAlpha: Theme.popupTransparency
                    readonly property real effectiveShadowAlpha: Math.max(0, Math.min(1, shadowBaseAlpha * popupSurfaceAlpha))

                    opacity: menuRoot.showMenu ? 1 : 0
                    scale: menuRoot.showMenu ? 1 : 0.85

                    Behavior on opacity {
                        NumberAnimation {
                            duration: Theme.mediumDuration
                            easing.type: Theme.emphasizedEasing
                        }
                    }

                    Behavior on scale {
                        NumberAnimation {
                            duration: Theme.mediumDuration
                            easing.type: Theme.emphasizedEasing
                        }
                    }

                    Item {
                        id: menuBgShadowLayer
                        anchors.fill: parent
                        layer.enabled: !BlurService.enabled
                        layer.smooth: true
                        layer.textureSize: Qt.size(Math.round(width * menuWindow.dpr), Math.round(height * menuWindow.dpr))
                        layer.textureMirroring: ShaderEffectSource.MirrorVertically

                        readonly property int blurMax: 64

                        layer.effect: MultiEffect {
                            autoPaddingEnabled: true
                            shadowEnabled: true
                            blurEnabled: false
                            maskEnabled: false
                            shadowBlur: Math.max(0, Math.min(1, trayMenuContainer.shadowBlurPx / menuBgShadowLayer.blurMax))
                            shadowScale: 1 + (2 * trayMenuContainer.shadowSpreadPx) / Math.max(1, Math.min(menuBgShadowLayer.width, menuBgShadowLayer.height))
                            shadowColor: {
                                const baseColor = Theme.isLightMode ? Qt.rgba(0, 0, 0, 1) : Theme.surfaceContainerHighest;
                                return Theme.withAlpha(baseColor, trayMenuContainer.effectiveShadowAlpha);
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            color: Theme.withAlpha(Theme.surfaceContainer, Theme.popupTransparency)
                            radius: Theme.cornerRadius
                            antialiasing: true
                        }
                    }

                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        radius: Theme.cornerRadius
                        border.color: BlurService.borderColor
                        border.width: BlurService.borderWidth
                        z: 100
                    }

                    QsMenuAnchor {
                        id: submenuHydrator
                        anchor.window: menuWindow
                    }

                    QsMenuOpener {
                        id: rootOpener
                        menu: menuRoot.menuHandle
                    }

                    QsMenuOpener {
                        id: subOpener
                        menu: {
                            const e = menuRoot.topEntry();
                            return e ? (e.menu || e) : null;
                        }
                    }

                    Column {
                        id: menuColumn

                        width: parent.width - Theme.spacingS * 2
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        anchors.topMargin: Theme.spacingS
                        spacing: 1

                        Rectangle {
                            visible: entryStack.count === 0
                            width: parent.width
                            height: 28
                            radius: Theme.cornerRadius
                            color: visibilityToggleArea.containsMouse ? BlurService.hoverColor(Theme.widgetBaseHoverColor) : Theme.withAlpha(Theme.surfaceContainer, 0)

                            StyledText {
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                text: menuRoot.trayItem?.id || "Unknown"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceTextMedium
                                elide: Text.ElideMiddle
                                width: parent.width - Theme.spacingS * 2 - 24
                            }

                            DIcon {
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                name: SessionData.isHiddenTrayId(root.getTrayItemKey(menuRoot.trayItem)) ? "visibility" : "visibility_off"
                                size: 16
                                color: Theme.widgetTextColor
                            }

                            MouseArea {
                                id: visibilityToggleArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    const itemKey = root.getTrayItemKey(menuRoot.trayItem);
                                    if (!itemKey)
                                        return;
                                    if (SessionData.isHiddenTrayId(itemKey)) {
                                        SessionData.showTrayId(itemKey);
                                    } else {
                                        SessionData.hideTrayId(itemKey);
                                    }
                                    menuRoot.closeWithAction();
                                }
                            }
                        }

                        Rectangle {
                            visible: entryStack.count === 0
                            width: parent.width
                            height: 1
                            color: Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.2)
                        }

                        Rectangle {
                            visible: entryStack.count > 0
                            width: parent.width
                            height: 28
                            radius: Theme.cornerRadius
                            color: backArea.containsMouse ? BlurService.hoverColor(Theme.widgetBaseHoverColor) : Theme.withAlpha(Theme.surfaceContainer, 0)

                            Row {
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingXS

                                DIcon {
                                    name: "arrow_back"
                                    size: 16
                                    color: Theme.widgetTextColor
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: I18n.tr("Back")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.widgetTextColor
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            MouseArea {
                                id: backArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: menuRoot.goBack()
                            }
                        }

                        Rectangle {
                            visible: entryStack.count > 0
                            width: parent.width
                            height: 1
                            color: Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.2)
                        }

                        Repeater {
                            model: entryStack.count ? (subOpener.children ? subOpener.children : (menuRoot.topEntry()?.children || [])) : rootOpener.children

                            Rectangle {
                                property var menuEntry: modelData

                                width: menuColumn.width
                                height: menuEntry?.isSeparator ? 1 : 28
                                radius: menuEntry?.isSeparator ? 0 : Theme.cornerRadius
                                color: {
                                    if (menuEntry?.isSeparator)
                                        return Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.2);
                                    return itemArea.containsMouse ? BlurService.hoverColor(Theme.widgetBaseHoverColor) : Theme.withAlpha(Theme.surfaceContainer, 0);
                                }

                                MouseArea {
                                    id: itemArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    enabled: !menuEntry?.isSeparator && (menuEntry?.enabled !== false)
                                    cursorShape: Qt.PointingHandCursor

                                    onClicked: {
                                        if (!menuEntry || menuEntry.isSeparator)
                                            return;
                                        if (menuEntry.hasChildren) {
                                            menuRoot.showSubMenu(menuEntry);
                                            return;
                                        }

                                        if (typeof menuEntry.activate === "function") {
                                            menuEntry.activate();
                                        } else if (typeof menuEntry.triggered === "function") {
                                            menuEntry.triggered();
                                        }
                                        pendingActionCloseTimer.restart();
                                    }
                                }

                                Row {
                                    anchors.left: parent.left
                                    anchors.leftMargin: Theme.spacingS
                                    anchors.right: parent.right
                                    anchors.rightMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spacingXS
                                    visible: !menuEntry?.isSeparator

                                    Rectangle {
                                        width: 16
                                        height: 16
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: menuEntry?.buttonType !== undefined && menuEntry.buttonType !== 0
                                        radius: menuEntry?.buttonType === 2 ? 8 : 2
                                        border.width: 1
                                        border.color: Theme.outline
                                        color: "transparent"

                                        Rectangle {
                                            anchors.centerIn: parent
                                            width: parent.width - 6
                                            height: parent.height - 6
                                            radius: parent.radius - 3
                                            color: Theme.primary
                                            visible: menuEntry?.checkState === 2
                                        }

                                        DIcon {
                                            anchors.centerIn: parent
                                            name: "check"
                                            size: 10
                                            color: Theme.primaryText
                                            visible: menuEntry?.buttonType === 1 && menuEntry?.checkState === 2
                                        }
                                    }

                                    Item {
                                        width: 16
                                        height: 16
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: (menuEntry?.icon ?? "") !== ""

                                        Image {
                                            anchors.fill: parent
                                            source: menuEntry?.icon || ""
                                            sourceSize.width: 16
                                            sourceSize.height: 16
                                            fillMode: Image.PreserveAspectFit
                                            smooth: true
                                        }
                                    }

                                    StyledText {
                                        text: menuEntry?.text || ""
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: (menuEntry?.enabled !== false) ? Theme.surfaceText : Theme.surfaceTextMedium
                                        elide: Text.ElideRight
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: Math.max(150, parent.width - 64)
                                        wrapMode: Text.NoWrap
                                    }

                                    Item {
                                        width: 16
                                        height: 16
                                        anchors.verticalCenter: parent.verticalCenter

                                        DIcon {
                                            anchors.centerIn: parent
                                            name: "chevron_right"
                                            size: 14
                                            color: Theme.widgetTextColor
                                            visible: menuEntry?.hasChildren ?? false
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    function openOverflowMenu(entry, areaItem, mouse, anchorItem) {
        if (!entry || entry.kind !== "overflow")
            return;
        const hiddenItems = entry.hiddenItems || [];
        if (!hiddenItems.length)
            return;

        if (tooltipLoader.item)
            tooltipLoader.item.hide();
        tooltipLoader.active = false;

        overflowMenuLoader.active = true;
        if (!overflowMenuLoader.item)
            return;

        const rowCount = Math.min(hiddenItems.length, 9);
        const menuHeight = Math.max(38, rowCount * 38 + 8);

        if (root.isVertical) {
            const globalPos = areaItem.mapToGlobal(areaItem.width / 2, areaItem.height / 2);
            const screenY = root.parentScreen ? root.parentScreen.y : 0;
            const relativeY = globalPos.y - screenY;
            const isLeft = root.axis?.edge === "left";
            const xPos = isLeft ? (root.barThickness + root.barSpacing + Theme.spacingXS) : ((root.parentScreen?.width ?? Screen.width) - root.barThickness - root.barSpacing - Theme.spacingXS - 240);
            overflowMenuLoader.item.showFor(hiddenItems, xPos, relativeY, true, root.axis?.edge, false);
            return;
        }

        const globalPos = areaItem.mapToGlobal(areaItem.width / 2, areaItem.height / 2);
        const screenX = root.parentScreen ? root.parentScreen.x : 0;
        const relativeX = globalPos.x - screenX;
        const screenHeight = root.parentScreen ? root.parentScreen.height : Screen.height;
        const isBottom = root.axis?.edge === "bottom";
        const yPos = isBottom ? (screenHeight - root.barThickness - root.barSpacing - menuHeight - Theme.spacingXS) : (root.barThickness + root.barSpacing + Theme.spacingXS);
        overflowMenuLoader.item.showFor(hiddenItems, relativeX, yPos, false, root.axis?.edge, false);
    }

    function openHiddenItemsMenu(entry, areaItem, mouse, anchorItem) {
        if (!entry || entry.kind !== "hidden")
            return;
        const hiddenItems = entry.hiddenItems || [];
        if (!hiddenItems.length)
            return;

        if (tooltipLoader.item)
            tooltipLoader.item.hide();
        tooltipLoader.active = false;

        overflowMenuLoader.active = true;
        if (!overflowMenuLoader.item)
            return;

        const rowCount = Math.min(hiddenItems.length, 9);
        const menuHeight = Math.max(38, rowCount * 38 + 8);

        if (root.isVertical) {
            const globalPos = areaItem.mapToGlobal(areaItem.width / 2, areaItem.height / 2);
            const screenY = root.parentScreen ? root.parentScreen.y : 0;
            const relativeY = globalPos.y - screenY;
            const isLeft = root.axis?.edge === "left";
            const xPos = isLeft ? (root.barThickness + root.barSpacing + Theme.spacingXS) : ((root.parentScreen?.width ?? Screen.width) - root.barThickness - root.barSpacing - Theme.spacingXS - 240);
            overflowMenuLoader.item.showFor(hiddenItems, xPos, relativeY, true, root.axis?.edge, true);
            return;
        }

        const globalPos = areaItem.mapToGlobal(areaItem.width / 2, areaItem.height / 2);
        const screenX = root.parentScreen ? root.parentScreen.x : 0;
        const relativeX = globalPos.x - screenX;
        const screenHeight = root.parentScreen ? root.parentScreen.height : Screen.height;
        const isBottom = root.axis?.edge === "bottom";
        const yPos = isBottom ? (screenHeight - root.barThickness - root.barSpacing - menuHeight - Theme.spacingXS) : (root.barThickness + root.barSpacing + Theme.spacingXS);
        overflowMenuLoader.item.showFor(hiddenItems, relativeX, yPos, false, root.axis?.edge, true);
    }

    function openContextMenu(entry, areaItem, mouse, anchorItem) {
        if (!entry)
            return;

        if (tooltipLoader.item)
            tooltipLoader.item.hide();
        tooltipLoader.active = false;

        // One menu contains the native tray actions, hide/show, pinning and
        // window controls. TrayMenuContent hydrates the lazy SNI menu model.
        windowContextMenuLoader.active = true;
        if (!windowContextMenuLoader.item)
            return;

        windowContextMenuLoader.item.currentEntry = entry;
        windowContextMenuLoader.item.currentAnchorItem = anchorItem;
        windowContextMenuLoader.item.triggerBarThickness = root.barThickness;
        windowContextMenuLoader.item.triggerBarSpacing = root.barSpacing;

        if (root.isVertical) {
            const globalPos = areaItem.mapToGlobal(areaItem.width / 2, areaItem.height / 2);
            const screenY = root.parentScreen ? root.parentScreen.y : 0;
            const relativeY = globalPos.y - screenY;
            const adjustedY = relativeY + root.minTooltipY;
            const xPos = root.axis?.edge === "left" ? (root.barThickness + root.barSpacing + Theme.spacingXS) : ((root.parentScreen?.width ?? Screen.width) - root.barThickness - root.barSpacing - Theme.spacingXS);
            windowContextMenuLoader.item.showAt(xPos, adjustedY, true, root.axis?.edge);
        } else {
            const globalPos = areaItem.mapToGlobal(areaItem.width / 2, 0);
            const screenX = root.parentScreen ? root.parentScreen.x : 0;
            const relativeX = globalPos.x - screenX;
            const screenHeight = root.parentScreen ? root.parentScreen.height : Screen.height;
            const isBottom = root.axis?.edge === "bottom";
            const yPos = isBottom ? (screenHeight - root.barThickness - root.barSpacing - Theme.spacingXS) : (root.barThickness + root.barSpacing + Theme.spacingXS);
            windowContextMenuLoader.item.showAt(relativeX, yPos, false, root.axis?.edge);
        }
    }

    function showForTrayItem(item, anchor, screen, atBottom, vertical, axisObj) {
        if (!screen)
            return;
        if (root.currentTrayMenu) {
            root.currentTrayMenu.showMenu = false;
            root.currentTrayMenu.destroy();
            root.currentTrayMenu = null;
        }

        PopoutManager.closeAllPopouts();
        ModalManager.closeAllModalsExcept(null);

        root.currentTrayMenu = trayMenuComponent.createObject(null);
        if (!root.currentTrayMenu)
            return;
        root.currentTrayMenu.showForTrayItem(item, anchor, screen, atBottom, vertical ?? false, axisObj);
    }

    function callContextMenuFallback(trayItemId, globalX, globalY) {
        TrayMenuManager.callContextMenuFallback(trayItemId, globalX, globalY);
    }

    // ---- Matching.js forwarding -------------------------------------------
    // One canonical matching vocabulary lives in js/Matching.js (shared
    // with the Node unit tests). These thin forwards keep call sites
    // short and give the hot norm() path a memo cache.
    function cleanText(value) {
        return Matching.cleanText(value);
    }

    function norm(value) {
        return Matching.norm(value);
    }

    function uniq(values) {
        return Matching.uniq(values);
    }

    function getTrayItemKey(item) {
        return TrayMenuManager.getTrayItemKey(item, root.availableTrayItems);
    }

    function trayItemKey(item) {
        // Join key for the PID-scan output. Matches the key format produced
        // by scripts/tray_pid_scan.py (id US title US tooltip title).
        // NOTE: this is a *matching* key, deliberately NOT the display key —
        // titles change (VPN status, transfer rates), display keys must not.
        return cleanText(item?.id) + "\u001f" + cleanText(item?.title) + "\u001f" + cleanText(item?.tooltipTitle);
    }

    function trayDisplayKey(item) {
        // Stable display/identity key, shared with the built-in tray via
        // TrayMenuManager (id + ::n disambiguation, cached per item object).
        // Using it for ScriptModel's objectProp keeps delegates alive across
        // title churn and makes tray order interoperable with SystemTrayBar.
        return TrayMenuManager.getTrayItemKey(item, root.availableTrayItems);
    }

    function trayTitle(item) {
        return item?.tooltipTitle || item?.title || item?.id || "Tray item";
    }

    function trayFallbackText(item) {
        const title = trayTitle(item);
        return title ? title.charAt(0).toUpperCase() : "?";
    }

    function trayIconSourceFor(trayItem) {
        let icon = trayItem && trayItem.icon;
        if (typeof icon === "string" || icon instanceof String) {
            if (icon === "")
                return "";
            if (icon.includes("?path=")) {
                const split = icon.split("?path=");
                if (split.length !== 2)
                    return icon;
                const name = split[0];
                const path = split[1];
                let fileName = name.substring(name.lastIndexOf("/") + 1);
                if (fileName.startsWith("dropboxstatus"))
                    fileName = `hicolor/16x16/status/${fileName}`;
                return `file://${path}/${fileName}`;
            }
            if (icon.startsWith("/") && !icon.startsWith("file://"))
                return `file://${icon}`;
            return icon;
        }
        return "";
    }

    function effectiveAppId(appId) {
        root._appIdSubstitutionsTrigger;
        return Paths.moddedAppId(appId || "");
    }

    function appIconSourceFor(appId) {
        root._desktopEntriesUpdateTrigger;
        const effective = effectiveAppId(appId);
        if (!effective)
            return "";
        const desktopEntry = DesktopEntries.heuristicLookup(effective);
        const icon = Paths.getAppIcon(effective, desktopEntry);
        if (icon && icon !== "")
            return icon;
        // Some desktop entries use an icon name Steam does not publish as a
        // theme icon, which left the running Steam window without an icon.
        const id = norm(effective);
        const name = norm(appNameFor(effective));
        if (steamIconService.steamPath && (id.includes("steam") || name.includes("steam")))
            return steamIconService.steamPath;
        return icon;
    }

    function appNameFor(appId) {
        root._desktopEntriesUpdateTrigger;
        const effective = effectiveAppId(appId);
        if (!effective)
            return "Unknown";
        const desktopEntry = DesktopEntries.heuristicLookup(effective);
        return Paths.getAppName(effective, desktopEntry);
    }

    function groupKeyForAppId(appId) {
        return norm(effectiveAppId(appId) || appId);
    }

    function buildWindowGroups(toplevels) {
        const groups = {};
        const order = [];
        for (let i = 0; i < (toplevels || []).length; i++) {
            const toplevel = toplevels[i];
            // Respect apps that asked out of the switcher (same filter as
            // the built-in RunningApps), e.g. scratchpad-adjacent helpers.
            if (toplevel?.skipSwitcher)
                continue;
            const appId = toplevel?.appId || "";
            if (!appId)
                continue;
            const key = groupKeyForAppId(appId);
            if (!key)
                continue;
            if (!groups[key]) {
                groups[key] = {
                    "key": key,
                    "appId": appId,
                    "windows": [],
                    "isFocused": false
                };
                order.push(key);
            }
            groups[key].windows.push(toplevel);
            groups[key].isFocused = groups[key].isFocused || !!toplevel.activated;
        }
        return order.map(key => groups[key]);
    }

    function trayNamesFor(trayItem) {
        return Matching.trayNames(trayItem);
    }

    function procHintsForTrayItem(trayItem) {
        const entry = root.trayNameMap[root.trayItemKey(trayItem)];
        if (!entry || !entry.length)
            return [];
        return entry.filter(s => s && s.length >= 2);
    }

    function isInputMethodTray(trayItem) {
        const text = [
            trayItem?.id || "",
            trayItem?.title || "",
            trayItem?.tooltipTitle || ""
        ].join(" ").toLowerCase();
        return text.indexOf("fcitx") !== -1
            || text.indexOf("ibus") !== -1
            || text.indexOf("input method") !== -1
            || text.indexOf("inputmethod") !== -1;
    }

    function scoreNamesAgainstAppId(names, procHints, appIdValue) {
        return Matching.scoreAgainstAppId(names, procHints, appIdValue);
    }

    function findWindowGroupsForTrayItem(trayItem, groups) {
        const names = trayNamesFor(trayItem);
        const procHints = procHintsForTrayItem(trayItem);
        if (!names.length && !procHints.length)
            return [];

        const matches = [];
        for (let i = 0; i < groups.length; i++) {
            const group = groups[i];
            const score = Math.max(
                scoreNamesAgainstAppId(names, procHints, group.appId),
                scoreNamesAgainstAppId(names, procHints, effectiveAppId(group.appId))
            );
            if (score > 0)
                matches.push({
                    "group": group,
                    "score": score
                });
        }

        if (!matches.length)
            return [];
        matches.sort((a, b) => b.score - a.score);
        const topScore = matches[0].score;
        return matches.filter(m => m.score === topScore).map(m => m.group);
    }

    function niriCandidatesByPid(trayItem) {
        const pids = root.trayPidMap[root.trayItemKey(trayItem)];
        if (!pids || !pids.length)
            return [];
        const wins = NiriService.windows || [];
        return wins.filter(w => w.pid !== undefined && w.pid !== null && pids.indexOf(w.pid) !== -1);
    }

    function niriCandidatesByName(trayItem) {
        const names = trayNamesFor(trayItem);
        const procHints = procHintsForTrayItem(trayItem);
        if (!names.length && !procHints.length)
            return [];

        const wins = NiriService.windows || [];
        const matches = [];
        for (let i = 0; i < wins.length; i++) {
            const win = wins[i];
            const score = scoreNamesAgainstAppId(names, procHints, win.app_id);
            if (score > 0)
                matches.push({
                    "window": win,
                    "score": score
                });
        }
        if (!matches.length)
            return [];
        matches.sort((a, b) => b.score - a.score);
        const topScore = matches[0].score;
        return matches.filter(m => m.score === topScore).map(m => m.window);
    }

    function findNiriCandidatesForTrayItem(trayItem) {
        if (!CompositorService.isNiri)
            return [];
        const byPid = niriCandidatesByPid(trayItem);
        if (byPid.length)
            return byPid;
        return niriCandidatesByName(trayItem);
    }

    function desktopEntryForAppId(appId) {
        if (!appId)
            return null;
        const raw = String(appId);
        const modded = Paths.moddedAppId(raw);
        const entry = DesktopEntries.heuristicLookup(raw);
        if (entry)
            return entry;
        // Steam's window reports app_id "steam", while its desktop file is
        // "steam.desktop"; without this the window shows up as bare "Steam".
        if (modded.includes("steam")) {
            for (const id of ["steam.desktop"]) {
                try {
                    const byId = DesktopEntries.byId(id);
                    if (byId)
                        return byId;
                } catch (e) {}
            }
        }
        return modded !== raw ? DesktopEntries.heuristicLookup(modded) : null;
    }

    function desktopEntryForUnifiedEntry(entry) {
        if (!entry)
            return null;
        const candidates = [entry.pinnedAppId, entry.appId, entry.trayItem?.id, entry.trayItem?.tooltipTitle, entry.trayItem?.title];
        for (let i = 0; i < candidates.length; i++) {
            const desktopEntry = root.desktopEntryForAppId(candidates[i]);
            if (desktopEntry)
                return desktopEntry;
        }
        return null;
    }

    function newWindowActionForEntry(entry) {
        const desktopEntry = root.desktopEntryForUnifiedEntry(entry);
        const actions = desktopEntry?.actions || [];
        for (let i = 0; i < actions.length; i++) {
            if (String(actions[i]?.id || "").toLowerCase() === "new-window")
                return actions[i];
        }
        return null;
    }

    function launchNewWindow(entry) {
        const desktopEntry = root.desktopEntryForUnifiedEntry(entry);
        const action = root.newWindowActionForEntry(entry);
        if (desktopEntry && action)
            SessionService.launchDesktopAction(desktopEntry, action);
    }

    function appIdVariants(appId) {
        if (!appId)
            return [];
        const raw = String(appId);
        return uniq([norm(raw), norm(Paths.moddedAppId(raw))]).filter(value => value.length > 0);
    }

    function entryMatchIds(entry) {
        if (!entry)
            return [];
        return uniq([
            norm(entry.appId),
            norm(entry.pinnedAppId),
            norm(entry.trayItem?.id),
            norm(entry.trayItem?.title),
            norm(entry.trayItem?.tooltipTitle)
        ]).filter(value => value.length > 0);
    }

    function entryMatchesPinnedId(id, entry) {
        if (!id || !entry)
            return false;
        const variants = appIdVariants(id);
        if (!variants.length)
            return false;
        const ids = entryMatchIds(entry);
        if (variants.some(value => ids.indexOf(value) !== -1))
            return true;
        // Tray-only apps often expose a friendly title (e.g. "FlClash")
        // instead of their desktop id (com.follow.clash). Match by the
        // desktop entry name too, then fall back to the same loose
        // containment vocabulary the window matcher uses, so a pinned id,
        // a running window and a tray item can never disagree about
        // "same app" and render twice.
        const desktopName = norm(desktopEntryForAppId(id)?.name);
        const targets = desktopName.length > 0 ? variants.concat([desktopName]) : variants;
        return Matching.looseMatchIds(ids, targets);
    }

    function canonicalPinnedIdForEntry(entry) {
        if (!entry)
            return "";
        if (entry.pinnedAppId)
            return String(entry.pinnedAppId);
        const candidates = [entry.appId, entry.trayItem?.id, entry.trayItem?.tooltipTitle, entry.trayItem?.title];
        for (let i = 0; i < candidates.length; i++) {
            const candidate = candidates[i];
            if (!candidate)
                continue;
            const desktopEntry = desktopEntryForAppId(candidate);
            if (desktopEntry?.id)
                return String(desktopEntry.id);
        }
        return entry.appId ? Paths.moddedAppId(String(entry.appId)) : "";
    }

    function isEntryPinned(entry) {
        if (!entry)
            return false;
        const pinned = SessionData.barPinnedApps || [];
        return pinned.some(id => entryMatchesPinnedId(id, entry));
    }

    function pinEntry(entry) {
        const id = canonicalPinnedIdForEntry(entry);
        if (id)
            SessionData.addBarPinnedApp(id);
    }

    function unpinEntry(entry) {
        if (!entry)
            return;
        const pinned = SessionData.barPinnedApps || [];
        const next = pinned.filter(id => !entryMatchesPinnedId(id, entry));
        if (next.length !== pinned.length)
            SessionData.setBarPinnedApps(next);
    }

    function togglePinEntry(entry) {
        if (!entry)
            return;
        if (isEntryPinned(entry))
            unpinEntry(entry);
        else
            pinEntry(entry);
    }

    function launchPinnedApp(appId) {
        if (!appId)
            return;
        const desktopEntry = desktopEntryForAppId(appId);
        if (desktopEntry && desktopEntry.command) {
            SessionService.launchDesktopEntry(desktopEntry);
            return;
        }
        Quickshell.execDetached([String(appId)]);
    }

    function buildDisplayedItems() {
        const items = root.unifiedItems || [];
        const hiddenItems = root.hiddenTrayEntries || [];
        const maxItems = root.maxVisibleItems;
        let displayed;

        if (maxItems <= 0 || items.length <= maxItems) {
            displayed = [...items];
        } else {
            const visibleCount = Math.max(0, maxItems - 1);
            displayed = items.slice(0, visibleCount);
            const overflowItems = items.slice(visibleCount);
            displayed.push({
                "key": "overflow:menu",
                "kind": "overflow",
                "hiddenItems": overflowItems,
                "trayItem": null,
                "windows": [],
                "niriWindows": [],
                "appId": "",
                "iconSource": "",
                "fallbackText": "",
                "tooltipText": I18n.tr("%1 more apps").arg(overflowItems.length),
                "windowCount": overflowItems.length,
                "isFocused": false,
                "needsAttention": false,
                "isPassive": false,
                "isPinned": false
            });
        }

        if (hiddenItems.length > 0) {
            displayed.push({
                "key": "hidden:tray-menu",
                "kind": "hidden",
                "hiddenItems": hiddenItems,
                "trayItem": null,
                "windows": [],
                "niriWindows": [],
                "appId": "",
                "iconSource": "",
                "fallbackText": "",
                "tooltipText": I18n.tr("隐藏的托盘图标 (%1)").arg(hiddenItems.length),
                "windowCount": 0,
                "isFocused": false,
                "needsAttention": false,
                "isPassive": false,
                "isPinned": false
            });
        }
        return displayed;
    }

    function buildUnifiedItems() {
        root._desktopEntriesUpdateTrigger;
        root._toplevelsUpdateTrigger;
        root._appIdSubstitutionsTrigger;
        root.trayPidMap;
        root.trayNameMap;
        NiriService.windows;

        const groups = root.windowGroups || [];
        const groupByKey = {};
        for (let i = 0; i < groups.length; i++)
            groupByKey[groups[i].key] = groups[i];

        const matchedWindowGroupKeys = new Set();
        const baseItems = [];

        for (let i = 0; i < root.allTrayItems.length; i++) {
            const trayItem = root.allTrayItems[i];
            const inputMethod = isInputMethodTray(trayItem);
            const niriWindows = inputMethod ? [] : findNiriCandidatesForTrayItem(trayItem);
            const matchedGroups = inputMethod ? [] : findWindowGroupsForTrayItem(trayItem, groups);

            for (let j = 0; j < niriWindows.length; j++) {
                const key = groupKeyForAppId(niriWindows[j].app_id);
                if (groupByKey[key] && matchedGroups.indexOf(groupByKey[key]) === -1)
                    matchedGroups.push(groupByKey[key]);
            }

            let windowCount = 0;
            let focused = false;
            let windows = [];
            let appId = "";
            for (let j = 0; j < matchedGroups.length; j++) {
                const group = matchedGroups[j];
                matchedWindowGroupKeys.add(group.key);
                windows = windows.concat(group.windows);
                windowCount += group.windows.length;
                focused = focused || group.isFocused;
                if (!appId)
                    appId = group.appId;
            }
            if (!windowCount && niriWindows.length) {
                windowCount = niriWindows.length;
                focused = niriWindows.some(w => w.is_focused);
                appId = niriWindows[0]?.app_id || "";
            }

            const title = trayTitle(trayItem);
            // SNI status: 0 Passive, 1 Active, 2 NeedsAttention. NeedsAttention
            // is the tray's only standardized "something happened, look at me"
            // signal — surface it so a muted chat or a failed sync is visible
            // without opening the tray menu. Passive means "registered but
            // idle", which we may dim.
            const sniStatus = Number(trayItem?.status ?? 1);
            const needsAttention = !inputMethod && sniStatus === 2;
            const isPassive = !inputMethod && sniStatus === 0 && windowCount === 0;
            const description = cleanText(trayItem?.tooltipDescription || "");
            const baseTooltip = inputMethod
                ? ("Input Method: " + title)
                : (windowCount > 0 ? (title + " (" + windowCount + " windows)") : title);
            const tooltipWithDescription = description && description !== title
                ? (baseTooltip + " — " + description)
                : baseTooltip;
            const displayKey = root.trayDisplayKey(trayItem);
            baseItems.push({
                "key": "tray:" + displayKey,
                "trayKey": displayKey,
                "kind": inputMethod ? "input" : "tray",
                "trayItem": trayItem,
                "windows": windows,
                "niriWindows": niriWindows,
                "appId": appId,
                "iconSource": trayIconSourceFor(trayItem),
                "fallbackText": trayFallbackText(trayItem),
                "tooltipText": tooltipWithDescription,
                "windowCount": windowCount,
                "isFocused": focused,
                "needsAttention": needsAttention,
                "isPassive": isPassive,
                "isPinned": false,
                "updateMenu": function () {
                    if (!trayItem || !trayItem.hasMenu || !trayItem.menu)
                        return;
                    if (typeof trayItem.menu.update === "function")
                        trayItem.menu.update();
                }
            });
        }

        for (let i = 0; i < groups.length; i++) {
            const group = groups[i];
            if (matchedWindowGroupKeys.has(group.key))
                continue;
            const name = appNameFor(group.appId);
            const title = group.windows.length === 1 ? (group.windows[0]?.title || "") : "";
            baseItems.push({
                "key": "window:" + group.key,
                "kind": "window",
                "trayItem": null,
                "windows": group.windows,
                "niriWindows": [],
                "appId": group.appId,
                "iconSource": appIconSourceFor(group.appId),
                "fallbackText": name ? name.charAt(0).toUpperCase() : "?",
                "tooltipText": name + (group.windows.length > 1 ? (" (" + group.windows.length + " windows)") : (title ? " - " + title : "")),
                "windowCount": group.windows.length,
                "isFocused": group.isFocused,
                "needsAttention": false,
                "isPassive": false,
                "isPinned": false
            });
        }

        // Fixed apps from SessionData.barPinnedApps go first. When dedupe is on,
        // a pinned app reuses its live tray/window entry instead of showing twice.
        const pinnedSource = root.showPinnedApps ? (SessionData.barPinnedApps || []) : [];
        const pinnedItems = [];
        const consumed = new Set();

        for (let i = 0; i < pinnedSource.length; i++) {
            const pinnedId = String(pinnedSource[i] || "");
            if (!pinnedId)
                continue;

            let matchedIndex = -1;
            if (root.dedupeApps) {
                for (let b = 0; b < baseItems.length; b++) {
                    if (consumed.has(b))
                        continue;
                    if (entryMatchesPinnedId(pinnedId, baseItems[b])) {
                        matchedIndex = b;
                        break;
                    }
                }
            }

            const desktopEntry = desktopEntryForAppId(pinnedId);
            const resolvedName = appNameFor(Paths.moddedAppId(pinnedId));
            const pinnedName = desktopEntry?.name || (resolvedName && resolvedName !== "Unknown" ? resolvedName : pinnedId);

            if (matchedIndex >= 0) {
                consumed.add(matchedIndex);
                const matched = baseItems[matchedIndex];
                pinnedItems.push(Object.assign({}, matched, {
                    "key": "pinned:" + pinnedId,
                    "isPinned": true,
                    "pinnedAppId": pinnedId,
                    "iconSource": matched.iconSource || appIconSourceFor(pinnedId),
                    "tooltipText": pinnedName + (matched.windowCount > 1 ? (" (" + matched.windowCount + " windows)") : "")
                }));
            } else {
                pinnedItems.push({
                    "key": "pinned:" + pinnedId,
                    "kind": "pinned",
                    "trayItem": null,
                    "windows": [],
                    "niriWindows": [],
                    "appId": Paths.moddedAppId(pinnedId),
                    "iconSource": appIconSourceFor(pinnedId),
                    "fallbackText": pinnedName ? pinnedName.charAt(0).toUpperCase() : "?",
                    "tooltipText": pinnedName,
                    "windowCount": 0,
                    "isFocused": false,
                    "needsAttention": false,
                    "isPassive": false,
                    "isPinned": true,
                    "pinnedAppId": pinnedId
                });
            }
        }

        const rest = [];
        for (let i = 0; i < baseItems.length; i++) {
            if (consumed.has(i))
                continue;
            const item = baseItems[i];
            if (item.kind === "window") {
                if (!root.showRunningApps)
                    continue;
            } else if (item.kind === "input") {
                if (!root.showTrayItems)
                    continue;
            } else if (!root.showTrayItems && !(root.showRunningApps && item.windowCount > 0)) {
                continue;
            }
            rest.push(item);
        }

        return pinnedItems.concat(rest);
    }

    // Dock-style click semantics (matches built-in RunningApps):
    // one window -> toggle (focus / minimize where supported),
    // several windows -> cycle to the next one, all through
    // CompositorService so minimize-restore and Niri overview closing are
    // handled in one place instead of raw toplevel.activate() calls.
    function cycleWindowGroup(windows) {
        if (!windows || !windows.length)
            return false;
        if (windows.length === 1) {
            CompositorService.toggleToplevel(windows[0]);
            return true;
        }
        const focusedIndex = windows.findIndex(w => w.activated);
        const next = windows[(focusedIndex + 1) % windows.length];
        CompositorService.activateToplevel(next);
        return true;
    }

    // Step through an entry's windows by wheel/touchpad direction.
    // Mirrors RunningApps: discrete 120 clicks step once, touchpad input
    // accumulates against a threshold so two-finger scrolls don't jump.
    function stepWindowGroup(windows, delta) {
        if (!windows || windows.length < 2)
            return false;
        const currentIndex = windows.findIndex(w => w.activated);
        const nextIndex = delta < 0
            ? (currentIndex === -1 ? 0 : Math.min(currentIndex + 1, windows.length - 1))
            : (currentIndex === -1 ? windows.length - 1 : Math.max(currentIndex - 1, 0));
        if (nextIndex !== currentIndex) {
            CompositorService.activateToplevel(windows[nextIndex]);
            return true;
        }
        return false;
    }

    function focusNiriWindowGroup(windows) {
        if (!windows || !windows.length)
            return false;

        let target = windows[0];
        if (windows.length > 1) {
            const focusedIndex = windows.findIndex(w => w.is_focused);
            if (focusedIndex >= 0)
                target = windows[(focusedIndex + 1) % windows.length];
        }

        if (!target || target.id === undefined || target.id === null)
            return false;
        NiriService.focusWindow(target.id);
        return true;
    }

    function focusExistingWindowForTrayItem(trayItem) {
        if (!trayItem || isInputMethodTray(trayItem))
            return false;
        if (Quickshell.env("DMS_TRAY_NO_FOCUS") === "1")
            return false;
        if (!CompositorService.isNiri)
            return false;
        return focusNiriWindowGroup(findNiriCandidatesForTrayItem(trayItem));
    }

    function fallbackActionFor(trayItem) {
        if (!trayItem)
            return null;
        const key = String(trayItem.id || "").toLowerCase();
        return root.activateFallbacks[key] ?? null;
    }

    function runFallback(trayItem, action) {
        const key = String(trayItem?.id || "").toLowerCase();
        const now = Date.now();
        // A double-click fires two clicks; keep the app launch idempotent.
        if (key === root._lastFallbackKey && now - root._lastFallbackAt < 1000)
            return;
        root._lastFallbackKey = key;
        root._lastFallbackAt = now;
        Quickshell.execDetached(action);
    }

    function activateTrayItem(trayItem) {
        if (!trayItem)
            return;
        if (focusExistingWindowForTrayItem(trayItem))
            return;
        const fallback = fallbackActionFor(trayItem);
        if (fallback) {
            runFallback(trayItem, fallback);
            return;
        }
        trayItem.activate();
    }

    function activateUnifiedItem(entry) {
        if (!entry)
            return;
        if (entry.kind === "overflow" || entry.kind === "hidden")
            return;
        if (entry.kind === "pinned") {
            launchPinnedApp(entry.pinnedAppId || entry.appId);
            return;
        }
        if (entry.kind === "input") {
            if (entry.trayItem)
                entry.trayItem.activate();
            return;
        }
        if (cycleWindowGroup(entry.windows))
            return;
        // Niri-only fallback: tray matched against NiriService windows when
        // no Quickshell toplevel exists for them.
        if (focusNiriWindowGroup(entry.niriWindows))
            return;
        // A pinned app whose tray item is a launcher (Steam, FlClash) must
        // bring its window forward instead of only re-running Activate().
        if (entry.trayItem && focusExistingWindowForTrayItem(entry.trayItem))
            return;
        if (entry.trayItem)
            activateTrayItem(entry.trayItem);
    }

    // Middle-click semantics: close the focused window of a window entry
    // (single-window entries just close it), or fire the tray item's
    // SecondaryActivate (SNI's designated alternate action).
    function middleClickUnifiedItem(entry) {
        if (!entry)
            return;
        if (entry.kind === "overflow" || entry.kind === "hidden" || entry.kind === "input")
            return;
        if (entry.trayItem && !(entry.windows?.length > 0)) {
            entry.trayItem.secondaryActivate();
            return;
        }
        const target = entry.windows?.find(w => w.activated) || entry.windows?.[0];
        if (target && typeof target.close === "function")
            target.close();
    }

    function showTooltip(anchorItem, text) {
        if (!text)
            return;
        tooltipLoader.active = true;
        if (!tooltipLoader.item)
            return;

        const localPos = anchorItem.mapToItem(null, anchorItem.width / 2, anchorItem.height / 2);
        if (root.isVertical) {
            const isLeft = root.axis?.edge === "left";
            const tooltipX = isLeft ? (root.barThickness + root.barSpacing + Theme.spacingXS) : ((root.parentScreen?.width ?? Screen.width) - root.barThickness - root.barSpacing - Theme.spacingXS);
            tooltipLoader.item.show(text, tooltipX, localPos.y + root.minTooltipY, root.parentScreen, isLeft, !isLeft);
            return;
        }

        const screenHeight = root.parentScreen ? root.parentScreen.height : Screen.height;
        const isBottom = root.axis?.edge === "bottom";
        const tooltipY = isBottom ? (screenHeight - root.barThickness - root.barSpacing - Theme.spacingXS - 35) : (root.barThickness + root.barSpacing + Theme.spacingXS);
        tooltipLoader.item.show(text, localPos.x, tooltipY, root.parentScreen, false, false);
    }

    function hideTooltip() {
        if (tooltipLoader.item)
            tooltipLoader.item.hide();
        tooltipLoader.active = false;
    }

    function rescanTrayPids() {
        if (!CompositorService.isNiri)
            return;
        if (!trayPidScanner.running)
            trayPidScanner.running = true;
    }

    function parseTrayScan(text) {
        const pidMap = ({});
        const nameMap = ({});
        const dup = ({});
        const lines = (text || "").split("\n");
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i];
            if (!line)
                continue;
            const parts = line.split("\t");
            if (parts.length < 2)
                continue;
            const key = parts[0];
            const pids = parts[1].split(",").map(s => parseInt(s, 10)).filter(n => !isNaN(n));
            const hints = (parts.length >= 3 && parts[2]) ? parts[2].split(",").filter(s => s) : [];
            if (pidMap[key] !== undefined) {
                dup[key] = true;
                continue;
            }
            pidMap[key] = pids;
            nameMap[key] = hints;
        }
        for (let key in dup) {
            pidMap[key] = null;
            nameMap[key] = null;
        }
        root.trayPidMap = pidMap;
        root.trayNameMap = nameMap;
    }

    readonly property string trayScanScriptPath: {
        // The scan script ships beside this QML file. Resolve relative to
        // the QML document itself so the plugin works from any install
        // prefix; fall back to the standard DMS plugin path if the engine
        // ever hands us a bare URL.
        const resolved = Qt.resolvedUrl("./scripts/tray_pid_scan.py").toString();
        if (resolved.startsWith("file://"))
            return resolved.substring("file://".length);
        const home = Quickshell.env("HOME") || "";
        if (home)
            return home + "/.config/dms/plugins/unifiedAppTray/scripts/tray_pid_scan.py";
        return resolved;
    }
}
