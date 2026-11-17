// The notification popups: a column of cards at the top right, under the bar's right plate,
// newest on top. Cards slide in from the right and out again when they go.
import QtQuick
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: popups

    visible: list.count > 0
    anchors.top: true
    anchors.right: true
    margins.top: 44
    margins.right: 8
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-notifications"
    color: "transparent"

    implicitWidth: 380
    implicitHeight: Math.max(1, list.contentHeight)

    ListView {
        id: list
        anchors.fill: parent
        interactive: false
        spacing: 8
        // The model adds new notifications at the end; drawing bottom to top puts them first.
        verticalLayoutDirection: ListView.BottomToTop
        model: Notifs.server.trackedNotifications

        delegate: NotificationCard {
            required property var modelData
            notification: modelData
        }

        add: Transition {
            NumberAnimation { property: "x"; from: 400; to: 0; duration: 220; easing.type: Easing.OutCubic }
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 160 }
        }
        remove: Transition {
            NumberAnimation { property: "x"; to: 400; duration: 200; easing.type: Easing.InCubic }
            NumberAnimation { property: "opacity"; to: 0; duration: 200 }
        }
        displaced: Transition {
            NumberAnimation { property: "y"; duration: 200; easing.type: Easing.OutCubic }
        }
    }
}
