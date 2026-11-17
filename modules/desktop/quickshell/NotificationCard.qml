// One notification as a cockpit plate: the app as a HUD tag and the time, the app's icon or the
// notification's image, summary and body, action buttons, and a strip along the bottom counting
// down to when it goes. Hovering pauses the countdown; a left click runs the default action, a
// right click dismisses it. Critical notifications stay until dismissed.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import Quickshell.Services.Notifications

Item {
    id: root

    required property var notification
    readonly property bool critical: notification.urgency === NotificationUrgency.Critical
    readonly property bool low: notification.urgency === NotificationUrgency.Low
    readonly property color tone: critical ? Theme.urgent : Theme.accent
    // Seconds on screen: the sender's choice when it gives one, otherwise by urgency.
    readonly property real lifetime: notification.expireTimeout > 0 ? notification.expireTimeout / 1000 : low ? 4 : 7
    readonly property bool expires: !critical && !notification.resident
    readonly property var defaultAction: notification.actions.find(a => a.identifier === "default") ?? null
    readonly property var buttons: notification.actions.filter(a => a.identifier !== "default")
    readonly property string picture: notification.image
        ? notification.image
        : notification.appIcon ? Quickshell.iconPath(notification.appIcon, true) : ""
    readonly property date arrived: new Date()

    property real remaining: 1

    implicitWidth: 380
    implicitHeight: content.implicitHeight + 28

    PlateShape {
        anchors.fill: parent
        cutTopLeft: 10
        cutBottomRight: 10
        fillOpacity: 0.97
        frameColor: root.tone
        stripRight: true
        opacity: root.low ? 0.85 : 1
    }

    // Counting down along the bottom edge, from full width to nothing.
    Rectangle {
        visible: root.expires
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 3
        x: 12
        height: 2
        width: (parent.width - 34) * root.remaining
        color: root.tone
        opacity: 0.7
    }

    NumberAnimation on remaining {
        id: countdown
        running: root.expires
        paused: hover.hovered
        from: 1
        to: 0
        duration: root.lifetime * 1000
        onFinished: root.notification.expire()
    }

    HoverHandler {
        id: hover
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: root.defaultAction ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: mouse => {
            if (mouse.button === Qt.LeftButton && root.defaultAction) root.defaultAction.invoke();
            root.notification.dismiss();
        }
    }

    RowLayout {
        id: content
        x: 14
        y: 14
        width: parent.width - 28
        spacing: 12

        // The image or icon, framed like a display inset.
        Item {
            visible: root.picture !== ""
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: 22
            implicitWidth: 40
            implicitHeight: 40

            Rectangle {
                anchors.fill: parent
                color: "transparent"
                border.width: 1
                border.color: Qt.rgba(root.tone.r, root.tone.g, root.tone.b, 0.5)
            }
            IconImage {
                anchors.fill: parent
                anchors.margins: 4
                source: root.picture
                asynchronous: true
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 5

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Tag {
                    text: root.critical ? "ALERT" : (root.notification.appName || "SYS").toUpperCase().slice(0, 18)
                    border.color: Qt.rgba(root.tone.r, root.tone.g, root.tone.b, 0.7)
                }
                Item {
                    Layout.fillWidth: true
                }
                Label {
                    text: Qt.formatDateTime(root.arrived, "HH:mm")
                    color: Theme.dim
                    font.pixelSize: 10
                    font.letterSpacing: 1
                }
            }
            Label {
                Layout.fillWidth: true
                visible: text !== ""
                text: root.notification.summary
                color: root.critical ? Theme.urgent : Theme.fg
                font.pixelSize: 13
                font.bold: true
                elide: Text.ElideRight
            }
            Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: root.notification.body
                textFormat: Text.StyledText
                color: Theme.dim
                font.family: Config.sans
                font.pixelSize: 12
                wrapMode: Text.Wrap
                maximumLineCount: 4
                elide: Text.ElideRight
                linkColor: Theme.accent
                onLinkActivated: link => Qt.openUrlExternally(link)
            }
            Flow {
                Layout.fillWidth: true
                Layout.topMargin: 2
                visible: root.buttons.length > 0
                spacing: 6

                Repeater {
                    model: root.buttons

                    Rectangle {
                        required property var modelData

                        implicitWidth: label.implicitWidth + 16
                        implicitHeight: 20
                        color: press.containsMouse ? Qt.rgba(root.tone.r, root.tone.g, root.tone.b, 0.2) : "transparent"
                        border.width: 1
                        border.color: Qt.rgba(root.tone.r, root.tone.g, root.tone.b, 0.7)

                        Label {
                            id: label
                            anchors.centerIn: parent
                            text: parent.modelData.text.toUpperCase()
                            color: root.tone
                            font.pixelSize: 10
                            font.bold: true
                            font.letterSpacing: 1
                        }
                        MouseArea {
                            id: press
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                parent.modelData.invoke();
                                root.notification.dismiss();
                            }
                        }
                    }
                }
            }
        }
    }
}
