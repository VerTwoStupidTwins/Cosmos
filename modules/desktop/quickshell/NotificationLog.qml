// The notification log: a LOG plate down the right of the screen, under the bar, listing the
// notifications kept in Notifs.history, newest first, by day. The header toggles do-not-disturb
// and clears the log; each entry's × forgets it. Esc or a click outside closes.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Services.Notifications

PanelWindow {
    id: log

    visible: Notifs.logOpen
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-notification-log"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    color: "transparent"

    function close() {
        Notifs.logOpen = false;
    }

    // A day heading over each day's first entry: TODAY, YESTERDAY or the date.
    function dayOf(time) {
        const d = new Date(time);
        const today = new Date();
        const yesterday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1);
        if (d.toDateString() === today.toDateString()) return "TODAY";
        if (d.toDateString() === yesterday.toDateString()) return "YESTERDAY";
        return Qt.formatDate(d, "ddd d MMM").toUpperCase();
    }

    onVisibleChanged: if (visible) list.forceActiveFocus()

    MouseArea {
        anchors.fill: parent
        onClicked: log.close()
    }

    Plate {
        id: plate
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 44
        anchors.rightMargin: 8
        width: 400
        height: Math.min(implicitHeight, parent.height - 44 - 16)
        title: "LOG"
        status: String(Notifs.history.length).padStart(2, "0") + " / " + Notifs.historyLimit
        cutTopLeft: 10
        cutBottomLeft: 14
        cutBottomRight: 0
        stripRight: true
        padding: 14

        // Slides in from the right.
        transform: Translate {
            x: log.visible ? 0 : 40
            Behavior on x {
                NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
            }
        }

        MouseArea {
            parent: plate
            anchors.fill: parent
            z: -1
        }

        // The controls: do-not-disturb and clear.
        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            LogButton {
                text: Notifs.dnd ? "DND ON" : "DND OFF"
                tone: Notifs.dnd ? Theme.warn : Theme.accent
                lit: Notifs.dnd
                onClicked: Notifs.toggleDnd()
            }
            Item {
                Layout.fillWidth: true
            }
            LogButton {
                text: "CLEAR"
                enabled: Notifs.history.length > 0
                onClicked: Notifs.clearHistory()
            }
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: 6
            implicitHeight: Math.max(contentHeight, 60)
            clip: true
            spacing: 6
            model: Notifs.history
            boundsBehavior: Flickable.StopAtBounds
            focus: true
            Keys.onEscapePressed: log.close()

            delegate: Item {
                id: entry

                required property var modelData
                required property int index
                readonly property bool critical: modelData.urgency === NotificationUrgency.Critical
                readonly property color tone: critical ? Theme.urgent : Theme.accent
                readonly property string day: log.dayOf(modelData.time)
                readonly property bool firstOfDay: index === 0 || log.dayOf(Notifs.history[index - 1].time) !== day
                readonly property string icon: {
                    const name = modelData.icon || "";
                    if (name === "") return "";
                    if (name.startsWith("/")) return "file://" + name;
                    return Quickshell.iconPath(name, true);
                }

                width: list.width
                height: card.y + card.height

                Label {
                    id: heading
                    visible: entry.firstOfDay
                    height: visible ? implicitHeight + 6 : 0
                    text: entry.day
                    color: Theme.muted
                    font.pixelSize: 9
                    font.letterSpacing: 2
                }

                Item {
                    id: card
                    y: heading.height
                    width: parent.width
                    height: content.implicitHeight + 16

                    HoverHandler {
                        id: hover
                    }

                    PlateShape {
                        anchors.fill: parent
                        cutTopLeft: 6
                        cutBottomRight: 6
                        fillOpacity: hover.hovered ? 0.7 : 0.45
                        showStrip: false
                        frameColor: Qt.rgba(entry.tone.r, entry.tone.g, entry.tone.b, entry.critical ? 0.8 : 0.35)
                    }

                    RowLayout {
                        id: content
                        x: 10
                        y: 8
                        width: parent.width - 20
                        spacing: 10

                        IconImage {
                            visible: entry.icon !== "" && status === Image.Ready
                            Layout.alignment: Qt.AlignTop
                            implicitSize: 22
                            source: entry.icon
                            asynchronous: true
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 3

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8

                                Tag {
                                    text: entry.critical ? "ALERT" : (entry.modelData.app || "SYS").toUpperCase().slice(0, 18)
                                    border.color: Qt.rgba(entry.tone.r, entry.tone.g, entry.tone.b, 0.7)
                                }
                                Item {
                                    Layout.fillWidth: true
                                }
                                Label {
                                    text: Qt.formatTime(new Date(entry.modelData.time), "HH:mm")
                                    color: Theme.dim
                                    font.pixelSize: 9
                                    font.letterSpacing: 1
                                }
                                // Forget this one.
                                Label {
                                    text: "×"
                                    color: forget.containsMouse ? Theme.urgent : Theme.muted
                                    font.pixelSize: 13
                                    opacity: hover.hovered ? 1 : 0.4

                                    MouseArea {
                                        id: forget
                                        anchors.fill: parent
                                        anchors.margins: -4
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: Notifs.forget(entry.modelData.id)
                                    }
                                }
                            }
                            Label {
                                Layout.fillWidth: true
                                visible: text !== ""
                                text: entry.modelData.summary
                                color: entry.critical ? Theme.urgent : Theme.fg
                                font.pixelSize: 12
                                font.bold: true
                                elide: Text.ElideRight
                            }
                            Text {
                                Layout.fillWidth: true
                                visible: text !== ""
                                text: entry.modelData.body
                                textFormat: Text.StyledText
                                color: Theme.dim
                                font.family: Config.sans
                                font.pixelSize: 11
                                wrapMode: Text.Wrap
                                maximumLineCount: 3
                                elide: Text.ElideRight
                                linkColor: Theme.accent
                                onLinkActivated: link => Qt.openUrlExternally(link)
                            }
                            // A screenshot's thumbnail, while the file is still there.
                            Image {
                                Layout.preferredWidth: 160
                                Layout.preferredHeight: status === Image.Ready ? 90 : 0
                                Layout.topMargin: status === Image.Ready ? 2 : 0
                                visible: status === Image.Ready
                                source: entry.modelData.image ?? ""
                                sourceSize.width: 320
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                            }
                        }
                    }
                }
            }
        }

        Label {
            Layout.fillWidth: true
            visible: Notifs.history.length === 0
            text: "NO NOTIFICATIONS"
            color: Theme.muted
            font.pixelSize: 10
            font.letterSpacing: 3
            horizontalAlignment: Text.AlignHCenter
        }
    }

    component LogButton: Rectangle {
        id: button

        property alias text: label.text
        property color tone: Theme.accent
        property bool lit: false
        signal clicked

        implicitWidth: label.implicitWidth + 16
        implicitHeight: 20
        opacity: enabled ? 1 : 0.4
        color: lit || press.containsMouse ? Qt.rgba(tone.r, tone.g, tone.b, 0.2) : "transparent"
        border.width: 1
        border.color: Qt.rgba(tone.r, tone.g, tone.b, 0.7)

        Label {
            id: label
            anchors.centerIn: parent
            color: button.tone
            font.pixelSize: 10
            font.bold: true
            font.letterSpacing: 1
        }
        MouseArea {
            id: press
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: button.clicked()
        }
    }
}
