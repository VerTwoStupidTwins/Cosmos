// A segmented meter whose bars rise left to right, lit up to `value` (0–1).
import QtQuick

Row {
    id: root

    property real value: 0
    property int segments: 10
    property color color: Theme.accent

    spacing: 2
    height: 12

    Repeater {
        model: root.segments

        Rectangle {
            required property int index

            width: 3
            height: 5 + index * (7 / Math.max(1, root.segments - 1))
            y: root.height - height
            color: index < Math.round(root.value * root.segments)
                ? root.color : Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.15)
        }
    }
}
