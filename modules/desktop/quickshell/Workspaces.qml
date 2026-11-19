// Workspaces over ext-workspace, as slanted plates numbered 01, 02…, with the icons of the apps
// on each from niri (Niri.qml). Click one to switch to it.
import QtQuick
import Quickshell
import Quickshell.Widgets
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
            // Up to three distinct apps' icons, then a count of the rest.
            readonly property var apps: Niri.appsOn(modelData.name)
            readonly property var shownApps: apps.slice(0, 3)
            readonly property int more: apps.length - shownApps.length

            function iconFor(appId) {
                const entry = DesktopEntries.heuristicLookup(appId);
                return Quickshell.iconPath(entry?.icon || appId, true);
            }

            width: 28 + (shownApps.length > 0 ? shownApps.length * 15 + (more > 0 ? 16 : 0) + 2 : 0)
            height: 18

            Behavior on width {
                NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
            }

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
                id: number
                x: 7
                anchors.verticalCenter: parent.verticalCenter
                text: String(button.modelData.name).padStart(2, "0")
                color: button.lit ? Theme.bg : Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.6)
                font.pixelSize: 11
                font.bold: button.lit
            }

            Row {
                anchors.left: number.right
                anchors.leftMargin: 5
                anchors.verticalCenter: parent.verticalCenter
                spacing: 3

                Repeater {
                    model: button.shownApps

                    IconImage {
                        required property string modelData
                        implicitSize: 12
                        source: button.iconFor(modelData)
                        asynchronous: true
                        // Dimmed on inactive workspaces, like the number.
                        opacity: button.lit ? 1 : 0.6
                    }
                }
                Label {
                    visible: button.more > 0
                    text: "+" + button.more
                    color: button.lit ? Theme.bg : Theme.dim
                    font.pixelSize: 9
                }
            }

            MouseArea {
                anchors.fill: parent
                onClicked: button.modelData.activate()
            }
        }
    }
}
