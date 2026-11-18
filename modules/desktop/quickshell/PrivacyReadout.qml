// Red tags while something captures: MIC, CAM and SCR, with the first app's name. Hovering shows
// them all.
import QtQuick
import QtQuick.Layouts

RowLayout {
    id: root

    readonly property var items: [
        { tag: "MIC", apps: Privacy.mic },
        { tag: "CAM", apps: Privacy.camera },
        { tag: "SCR", apps: Privacy.screen }
    ].filter(i => i.apps.length > 0)

    visible: items.length > 0
    spacing: 8

    Repeater {
        model: root.items

        RowLayout {
            id: item

            required property var modelData

            spacing: 5

            Tag {
                text: item.modelData.tag
                color: Qt.rgba(Theme.urgent.r, Theme.urgent.g, Theme.urgent.b, 0.25)
                border.color: Theme.urgent

                SequentialAnimation on opacity {
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.55; duration: 900; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
                }
            }
            Label {
                Layout.maximumWidth: 110
                text: item.modelData.apps.length > 1 ? item.modelData.apps[0] + " +" + (item.modelData.apps.length - 1) : item.modelData.apps[0]
                color: Theme.urgent
                elide: Text.ElideRight
            }
        }
    }
}
