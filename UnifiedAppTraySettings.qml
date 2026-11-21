import QtQuick
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root

    pluginId: "unifiedAppTray"

    StyledText {
        width: parent.width
        text: I18n.tr("统一应用托盘")
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Theme.fontWeightMedium
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: I18n.tr("把固定应用、运行中的窗口和系统托盘合并到一条。左键点击聚焦或启动，中键关闭窗口或执行托盘备用操作，滚轮切换同应用的多个窗口，按住拖动可调整图标顺序（运行中的应用也能拖），右键打开菜单。")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    StyledText {
        width: parent.width
        text: I18n.tr("显示内容")
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Theme.fontWeightMedium
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "showPinnedApps"
        label: I18n.tr("固定应用")
        description: I18n.tr("显示固定到面板的应用。右键任意应用图标即可固定或取消固定。")
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showRunningApps"
        label: I18n.tr("运行中的窗口")
        description: I18n.tr("显示当前打开的窗口应用，点击可聚焦或切换窗口。")
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showTrayItems"
        label: I18n.tr("系统托盘")
        description: I18n.tr("显示后台托盘应用，例如 Steam、FlClash 和输入法。")
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "dedupeApps"
        label: I18n.tr("合并重复应用")
        description: I18n.tr("同一个应用同时是固定应用、运行窗口或托盘图标时只显示一次，固定应用优先。")
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showAttentionDots"
        label: I18n.tr("需要关注角标")
        description: I18n.tr("托盘应用报告需要关注时（如新消息、同步失败），在图标角落显示闪烁圆点。")
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "dimPassiveItems"
        label: I18n.tr("淡化闲置托盘")
        description: I18n.tr("没有窗口且处于被动状态的托盘图标降低不透明度，让活跃应用更醒目。")
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "attentionClickDismiss"
        label: I18n.tr("点击即清除角标")
        description: I18n.tr("点击带红点的托盘图标时，红点立即熄灭，不用等应用自己撤销提醒状态。")
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "autoOverflow"
        label: I18n.tr("按可用宽度自动收纳")
        description: I18n.tr("分区空间放不下的图标自动收进溢出菜单；关闭后按固定数量上限收纳。")
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "filterByWorkspace"
        label: I18n.tr("只显示当前工作区")
        description: I18n.tr("仅显示当前工作区的窗口，切到别的工作区时隐藏其余窗口；与内置运行应用行为一致。")
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "showLauncherButton"
        label: I18n.tr("启动器按钮")
        description: I18n.tr("在托盘最前面显示应用启动器按钮。面板已有启动器时可以保持关闭。")
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "showOverflowBadge"
        label: I18n.tr("溢出数量角标")
        description: I18n.tr("超出最大显示数量时，在省略号按钮上显示 +N 角标。")
        defaultValue: true
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    StyledText {
        width: parent.width
        text: I18n.tr("外观与布局")
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Theme.fontWeightMedium
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "showIndicators"
        label: I18n.tr("运行指示点")
        description: I18n.tr("在图标靠近屏幕边缘的一侧显示运行指示点，与内置应用 Dock 一致。")
        defaultValue: true
    }

    SelectionSetting {
        settingKey: "indicatorSide"
        label: I18n.tr("指示点位置")
        description: I18n.tr("运行窗口点贴哪一侧：自动跟随 bar 所在边，或固定在上/下。红点角标始终待在它的对角，两种状态不挤同一侧。")
        options: [
            { value: "auto", label: I18n.tr("自动（跟 bar 边）") },
            { value: "top", label: I18n.tr("在上面") },
            { value: "bottom", label: I18n.tr("在下面") }
        ]
        defaultValue: "auto"
    }

    ToggleSetting {
        settingKey: "enlargeOnHover"
        label: I18n.tr("悬停放大")
        description: I18n.tr("鼠标悬停时放大图标，模拟 Dock 的悬停效果。")
        defaultValue: true
    }

    SliderSetting {
        settingKey: "enlargePercentage"
        label: I18n.tr("悬停放大比例")
        description: I18n.tr("悬停时图标相对原始大小的百分比。")
        defaultValue: 125
        minimum: 105
        maximum: 160
        unit: "%"
    }

    SliderSetting {
        settingKey: "iconSizePercent"
        label: I18n.tr("图标大小")
        description: I18n.tr("相对于面板默认图标大小的百分比。")
        defaultValue: 100
        minimum: 50
        maximum: 200
        unit: "%"
    }

    SliderSetting {
        settingKey: "itemSpacing"
        label: I18n.tr("图标间距")
        description: I18n.tr("相邻图标之间的像素间距。")
        defaultValue: Theme.spacingXS
        minimum: 0
        maximum: 24
        unit: "px"
    }

    SliderSetting {
        settingKey: "maxVisibleItems"
        label: I18n.tr("最大显示数量")
        description: I18n.tr("0 表示全部显示。超出数量的应用会收进末尾的省略号菜单。")
        defaultValue: 0
        minimum: 0
        maximum: 30
        unit: ""
    }
}
