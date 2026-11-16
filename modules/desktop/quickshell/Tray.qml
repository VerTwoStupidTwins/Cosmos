// Tray icons. Left click activates (or opens the menu for menu-only icons), right click opens
// the menu, middle click is the secondary action, scrolling is passed on.
import QtQuick
import Quickshell
import Quickshell.Services.SystemTray
import Quickshell.Widgets

Row {
    id: root
    required property var bar

    visible: icons.count > 0
    spacing: 8

    Repeater {
        id: icons
        model: SystemTray.items

        MouseArea {
            id: area
            required property var modelData

            width: 16
            height: 16
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

            IconImage {
                anchors.fill: parent
                source: area.modelData.icon
            }

            onClicked: mouse => {
                const item = area.modelData;
                if (mouse.button === Qt.MiddleButton) {
                    item.secondaryActivate();
                } else if (mouse.button === Qt.RightButton || item.onlyMenu) {
                    if (item.hasMenu) {
                        const p = area.mapToItem(null, 0, area.height);
                        item.display(root.bar, p.x, p.y + 6);
                    }
                } else {
                    item.activate();
                }
            }
            onWheel: wheel => area.modelData.scroll(wheel.angleDelta.y, false)
        }
    }
}
