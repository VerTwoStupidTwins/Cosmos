// One upright bar per CPU thread, filled to its usage (0–1).
import QtQuick
import QtQuick.Layouts

Row {
    id: root

    property var values: []

    Layout.fillWidth: true
    height: 26
    spacing: 3

    Repeater {
        model: root.values.length

        Item {
            required property int index
            readonly property real value: root.values[index] ?? 0

            width: (root.width - root.spacing * (root.values.length - 1)) / Math.max(1, root.values.length)
            height: root.height

            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.08)
            }
            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: Math.max(1, parent.height * parent.value)
                color: parent.value > 0.85 ? Theme.urgent : parent.value > 0.6 ? Theme.warn : Theme.accent

                Behavior on height {
                    NumberAnimation { duration: 400; easing.type: Easing.OutCubic }
                }
            }
        }
    }
}
