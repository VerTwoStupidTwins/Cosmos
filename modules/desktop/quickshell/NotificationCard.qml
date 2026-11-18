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

    // The notification's content, kept here: when it closes, the card still slides out, and by then
    // the notification itself is gone. Each binding stops updating once it is null.
    property string appName
    property string appIcon
    property string image
    property string summary
    property string body
    property int urgency: NotificationUrgency.Normal
    property real expireTimeout: -1
    property bool resident: false
    property var actions: []
    // Senders set x-cosmos-preview for an image worth seeing large, as Screenshots.qml does.
    property bool preview: false

    Binding on appName { when: root.notification !== null; value: root.notification?.appName ?? ""; restoreMode: Binding.RestoreNone }
    Binding on appIcon { when: root.notification !== null; value: root.notification?.appIcon ?? ""; restoreMode: Binding.RestoreNone }
    Binding on image { when: root.notification !== null; value: root.notification?.image ?? ""; restoreMode: Binding.RestoreNone }
    Binding on summary { when: root.notification !== null; value: root.notification?.summary ?? ""; restoreMode: Binding.RestoreNone }
    Binding on body { when: root.notification !== null; value: root.notification?.body ?? ""; restoreMode: Binding.RestoreNone }
    Binding on urgency { when: root.notification !== null; value: root.notification?.urgency ?? NotificationUrgency.Normal; restoreMode: Binding.RestoreNone }
    Binding on expireTimeout { when: root.notification !== null; value: root.notification?.expireTimeout ?? -1; restoreMode: Binding.RestoreNone }
    Binding on resident { when: root.notification !== null; value: root.notification?.resident ?? false; restoreMode: Binding.RestoreNone }
    Binding on preview { when: root.notification !== null; value: root.notification?.hints?.["x-cosmos-preview"] === true; restoreMode: Binding.RestoreNone }
    Binding on actions { when: root.notification !== null; value: Array.from(root.notification?.actions ?? []); restoreMode: Binding.RestoreNone }

    readonly property bool critical: urgency === NotificationUrgency.Critical
    readonly property bool low: urgency === NotificationUrgency.Low
    readonly property color tone: critical ? Theme.urgent : Theme.accent
    // Seconds on screen: the sender's choice when it gives one, otherwise by urgency.
    readonly property real lifetime: expireTimeout > 0 ? expireTimeout / 1000 : low ? 4 : 7
    readonly property bool expires: !critical && !resident
    readonly property var defaultAction: actions.find(a => a.identifier === "default") ?? null
    readonly property var buttons: actions.filter(a => a.identifier !== "default")
    // An image-path hint can be an icon name (udiskie sends "drive-removable-media"); check those
    // against the theme so a missing one falls back instead of drawing the missing-icon checkerboard.
    readonly property string picture: {
        const named = image.startsWith("image://icon/") ? Quickshell.iconPath(image.slice(13), true) : image;
        return named || (appIcon ? Quickshell.iconPath(appIcon, true) : "");
    }
    readonly property date arrived: new Date()

    // Running an action already closes the notification; only dismiss one that's still up.
    function close() {
        if (root.notification?.tracked) root.notification.dismiss();
    }

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
        onFinished: root.notification?.expire()
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
            root.close();
        }
    }

    RowLayout {
        id: content
        x: 14
        y: 14
        width: parent.width - 28
        spacing: 12

        // The image or icon, framed like a display inset (unless it's shown large below).
        Item {
            visible: root.picture !== "" && !root.preview
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
                    text: root.critical ? "ALERT" : (root.appName || "SYS").toUpperCase().slice(0, 18)
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
                text: root.summary
                color: root.critical ? Theme.urgent : Theme.fg
                font.pixelSize: 13
                font.bold: true
                elide: Text.ElideRight
            }
            Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: root.body
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
            // A large preview, framed like a display inset.
            Item {
                Layout.fillWidth: true
                Layout.topMargin: 4
                visible: root.preview && root.image !== ""
                implicitHeight: visible ? Math.round(width * 9 / 16) : 0

                PlateShape {
                    anchors.fill: parent
                    cutTopLeft: 8
                    cutBottomRight: 8
                    fillOpacity: 0.5
                    showStrip: false
                    frameColor: Qt.rgba(root.tone.r, root.tone.g, root.tone.b, 0.5)
                }
                Image {
                    anchors.fill: parent
                    anchors.margins: 4
                    source: root.preview ? root.image : ""
                    sourceSize.width: 700
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                }
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
                                root.close();
                            }
                        }
                    }
                }
            }
        }
    }
}
