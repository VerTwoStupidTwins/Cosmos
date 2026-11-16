// Workspaces over ext-workspace, which niri and Hyprland both speak, as slanted plates
// numbered 01, 02… Click one to switch to it.
import QtQuick
import Quickshell.WindowManager

Row {
    id: root

    // In layout order: by coordinates, compared item by item.
    readonly property var sets: Array.from(WindowManager.windowsets)
        .filter(ws => ws.shouldDisplay)
        .sort((a, b) => {
            const x = a.coordinates, y = b.coordinates;
            for (let i = 0; i < Math.max(x.length, y.length); i++) {
                const d = (x[i] ?? 0) - (y[i] ?? 0);
                if (d !== 0) return d;
            }
            return 0;
        })

    spacing: 4

    Repeater {
        model: root.sets

        Item {
            id: button
            required property var modelData
            readonly property bool lit: modelData.active || modelData.urgent
            readonly property color tone: modelData.urgent ? Theme.urgent : Theme.accent

            width: 28
            height: 18

            // The plate, slanted like a panel line; the number stays upright.
            Rectangle {
                anchors.fill: parent
                color: button.lit ? button.tone : "transparent"
                border.width: 1
                border.color: button.lit ? button.tone
                    : Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45)
                transform: Matrix4x4 {
                    matrix: Qt.matrix4x4(1, -0.35, 0, 0.35 * 9, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
                }
            }

            Label {
                anchors.centerIn: parent
                text: String(button.modelData.name).padStart(2, "0")
                color: button.lit ? Theme.bg : Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.6)
                font.pixelSize: 11
                font.bold: button.lit
            }

            MouseArea {
                anchors.fill: parent
                onClicked: button.modelData.activate()
            }
        }
    }
}
