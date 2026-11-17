// Three plates floating over the top edge: workspaces and target window on the left, the
// clock in the centre, status readouts on the right.
import QtQuick
import QtQuick.Layouts
import Quickshell

PanelWindow {
    id: bar

    anchors {
        top: true
        left: true
        right: true
    }
    implicitHeight: 40
    color: "transparent"

    Island {
        anchors.left: parent.left
        anchors.leftMargin: 8
        y: 6
        cutTopLeft: 4
        cutBottomRight: 14

        Workspaces {}
        Divider {}
        WindowTitle {
            Layout.maximumWidth: bar.width * 0.28
        }
    }

    Island {
        id: centre
        anchors.horizontalCenter: parent.horizontalCenter
        y: 6
        cutBottomLeft: 14
        cutBottomRight: 14

        Clock {}

        // Clicking the clock opens the command station below it.
        MouseArea {
            parent: centre
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: Station.toggle()
        }
    }

    StationPanel {
        screen: bar.screen
    }

    Island {
        anchors.right: parent.right
        anchors.rightMargin: 8
        y: 6
        cutTopRight: 4
        cutBottomLeft: 14
        stripRight: true

        // Notifications since the log was last opened, or DND while do-not-disturb is on.
        // Click for the log; right-click toggles do-not-disturb.
        Row {
            spacing: 6

            Tag {
                anchors.verticalCenter: parent.verticalCenter
                text: Notifs.dnd ? "DND" : "LOG"
                color: Notifs.dnd ? Qt.rgba(Theme.warn.r, Theme.warn.g, Theme.warn.b, 0.15) : "transparent"
                border.color: Notifs.dnd ? Theme.warn : Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.7)
            }
            Label {
                anchors.verticalCenter: parent.verticalCenter
                text: String(Math.min(Notifs.unread, 99)).padStart(2, "0")
                color: Notifs.unread > 0 ? Theme.fg : Theme.muted
            }

            MouseArea {
                parent: parent
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onClicked: mouse => mouse.button === Qt.RightButton ? Notifs.toggleDnd() : Notifs.toggleLog()
            }
        }
        Tray {
            bar: bar
        }
        Volume {}
        Brightness {}
        Network {}
        Battery {}
    }
}
