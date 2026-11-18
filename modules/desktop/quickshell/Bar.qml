// Three plates floating over the top edge: workspaces and target window on the left, the
// clock in the centre; capture indicators, recording, night light, caffeine, the notification
// log and the tray on the right. Media and the status readouts are on the bottom bar (BottomBar.qml).
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: bar

    anchors {
        top: true
        left: true
        right: true
    }
    implicitHeight: 40
    color: "transparent"

    // Caffeine: holding an idle inhibitor keeps the screen awake.
    IdleInhibitor {
        window: bar
        enabled: Caffeine.on
    }

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
            // Closes the lab page if that's what's down, otherwise toggles the station.
            onClicked: Homelab.open ? Homelab.open = false : Station.toggle()
        }
    }

    StationPanel {
        screen: bar.screen
    }
    LabPanel {
        screen: bar.screen
    }

    Island {
        anchors.right: parent.right
        anchors.rightMargin: 8
        y: 6
        cutTopRight: 4
        cutBottomLeft: 14
        stripRight: true

        // Red while an app records from the mic, uses a camera or captures the screen.
        PrivacyReadout {}

        // Recording: REC and the time, pulsing; click to stop.
        Item {
            visible: Recorder.recording
            implicitWidth: rec.implicitWidth
            implicitHeight: rec.implicitHeight

            Row {
                id: rec
                spacing: 5

                Tag {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "REC"
                    color: Qt.rgba(Theme.urgent.r, Theme.urgent.g, Theme.urgent.b, 0.3)
                    border.color: Theme.urgent

                    SequentialAnimation on opacity {
                        running: Recorder.recording
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.4; duration: 600 }
                        NumberAnimation { to: 1; duration: 600 }
                    }
                }
                Label {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Media.time(Recorder.elapsed)
                    color: Theme.urgent
                }
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: Recorder.stop()
            }
        }

        // Night light: lit warm while the screen is tinted. Click to toggle.
        Tag {
            text: "NGT"
            color: NightLight.on ? Qt.rgba(Theme.warn.r, Theme.warn.g, Theme.warn.b, 0.2) : "transparent"
            border.color: NightLight.on ? Theme.warn : Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.3)
            opacity: NightLight.on ? 1 : 0.6

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: NightLight.toggle()
            }
        }

        // Caffeine: dim while off, lit while the screen is kept awake. Click to toggle.
        Tag {
            text: "CAF"
            color: Caffeine.on ? Qt.rgba(Theme.warn.r, Theme.warn.g, Theme.warn.b, 0.2) : "transparent"
            border.color: Caffeine.on ? Theme.warn : Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.3)
            opacity: Caffeine.on ? 1 : 0.6

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: Caffeine.toggle()
            }
        }

        // Notifications since the log was last opened, or DND while do-not-disturb is on.
        // Click for the log; right-click toggles do-not-disturb.
        Item {
            implicitWidth: log.implicitWidth
            implicitHeight: log.implicitHeight

            Row {
                id: log
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
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onClicked: mouse => mouse.button === Qt.RightButton ? Notifs.toggleDnd() : Notifs.toggleLog()
            }
        }
        Tray {
            bar: bar
        }
    }
}
