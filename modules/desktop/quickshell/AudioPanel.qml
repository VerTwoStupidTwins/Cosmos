// The audio plate: rises over the bottom bar's right plate when VOL is clicked. Output and input
// devices, the chosen one of each with its volume and mute, and every app playing sound with its
// own. Click a device to make it the default; click or drag a level strip, or scroll on it, to set
// it; click a mute button to toggle it. Esc closes; pavucontrol is a button away.
// It closes itself after a few seconds (Panels.idleClose) without the pointer over it.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pipewire

PanelWindow {
    id: panel

    readonly property var nodes: Array.from(Pipewire.nodes.values).filter(n => n.audio)
    readonly property var sinks: nodes.filter(n => n.isSink && !n.isStream)
    readonly property var sources: nodes.filter(n => !n.isSink && !n.isStream)
    // Apps playing sound: output streams.
    readonly property var apps: nodes.filter(n => n.isSink && n.isStream)

    // Chromebook (UCM) devices are described as "<card id> <port>", e.g. "acp3xalc5682m98357
    // Speaker"; the card id, a word with digits in it, is dropped.
    function label(node) {
        const text = node.description || node.nickname || node.name;
        const short = text.replace(/^[a-z0-9_-]*\d[a-z0-9_-]*\s+/, "");
        return short || text;
    }
    function appLabel(node) {
        const p = node.properties;
        return p["application.name"] || p["media.name"] || label(node);
    }

    visible: Panels.open === "audio"
    anchors.bottom: true
    anchors.right: true
    margins.bottom: Tablet.barHeight + 2
    margins.right: 8
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-audio"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    color: "transparent"

    implicitWidth: 400
    implicitHeight: plate.implicitHeight + 4

    onVisibleChanged: if (visible) keys.forceActiveFocus()

    // Volume and mute only stay live for tracked nodes.
    PwObjectTracker {
        objects: panel.visible ? panel.nodes : []
    }

    Item {
        id: keys
        focus: true
        Keys.onEscapePressed: Panels.open = ""
    }

    // A few seconds without the pointer over the plate, it goes.
    // The handler is on the window, so the header counts too.
    HoverHandler {
        id: pointer
    }
    Timer {
        interval: Panels.idleClose
        running: panel.visible && !pointer.hovered
        onTriggered: Panels.open = ""
    }

    Plate {
        id: plate
        width: parent.width
        anchors.bottom: parent.bottom
        title: "AUD"
        status: String(panel.apps.length).padStart(2, "0") + " STREAMS"
        cutTopLeft: 14
        cutBottomRight: 4
        cutBottomLeft: 10
        stripRight: true
        padding: 14

        Section {
            text: "OUTPUT"
        }
        Repeater {
            model: panel.sinks

            Device {
                required property var modelData
                node: modelData
                current: Pipewire.defaultAudioSink === modelData
                onPicked: Pipewire.preferredDefaultAudioSink = modelData
            }
        }

        Section {
            text: "INPUT"
            visible: panel.sources.length > 0
        }
        Repeater {
            model: panel.sources

            Device {
                required property var modelData
                node: modelData
                current: Pipewire.defaultAudioSource === modelData
                onPicked: Pipewire.preferredDefaultAudioSource = modelData
            }
        }

        Section {
            text: "APPS"
            visible: panel.apps.length > 0
        }
        Repeater {
            model: panel.apps

            Level {
                required property var modelData
                Layout.fillWidth: true
                node: modelData
                name: panel.appLabel(modelData)
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 6

            Item {
                Layout.fillWidth: true
            }
            Rectangle {
                implicitWidth: pavuLabel.implicitWidth + 16
                implicitHeight: 20
                color: pavu.containsMouse ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.2) : "transparent"
                border.width: 1
                border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.7)

                Label {
                    id: pavuLabel
                    anchors.centerIn: parent
                    text: "MIXER"
                    color: Theme.accent
                    font.pixelSize: 10
                    font.bold: true
                    font.letterSpacing: 1
                }
                MouseArea {
                    id: pavu
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        Quickshell.execDetached([Config.pavucontrol]);
                        Panels.open = "";
                    }
                }
            }
        }
    }

    component Section: Label {
        Layout.topMargin: 6
        color: Theme.muted
        font.pixelSize: 9
        font.letterSpacing: 2
    }

    // A device: its name, picked as the default with a click; the current one shows its level.
    component Device: ColumnLayout {
        id: device

        required property var node
        property bool current: false
        signal picked

        Layout.fillWidth: true
        spacing: 4

        Item {
            Layout.fillWidth: true
            implicitHeight: 28

            HoverHandler {
                id: hover
            }
            PlateShape {
                anchors.fill: parent
                cutTopLeft: 6
                cutBottomRight: 6
                fillOpacity: device.current ? 0.8 : hover.hovered ? 0.6 : 0.3
                showStrip: false
                frameColor: device.current ? Theme.accent : Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, hover.hovered ? 0.5 : 0.2)
            }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 8

                Rectangle {
                    implicitWidth: 6
                    implicitHeight: 6
                    color: device.current ? Theme.accent : "transparent"
                    border.width: 1
                    border.color: device.current ? Theme.accent : Theme.muted
                }
                Label {
                    Layout.fillWidth: true
                    text: panel.label(device.node)
                    color: device.current ? Theme.fg : Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.8)
                    font.pixelSize: 11
                    font.bold: device.current
                    elide: Text.ElideRight
                }
            }
            MouseArea {
                anchors.fill: parent
                enabled: !device.current
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: device.picked()
            }
        }
        Level {
            Layout.fillWidth: true
            Layout.leftMargin: 10
            visible: device.current
            node: device.node
        }
    }

    // A level: mute button, segmented strip and percentage. Click or drag the strip, or scroll.
    component Level: RowLayout {
        id: level

        required property var node
        property string name: ""
        readonly property bool muted: node.audio?.muted ?? false
        readonly property real volume: node.audio?.volume ?? 0

        function set(v) {
            if (node.audio) node.audio.volume = Math.max(0, Math.min(1, v));
        }

        spacing: 8

        Item {
            implicitWidth: 22
            implicitHeight: 20

            Text {
                anchors.centerIn: parent
                text: level.muted ? "󰖁" : level.node.isSink ? "󰕾" : "󰍬"
                color: level.muted ? Theme.urgent : mute.containsMouse ? Theme.fg : Theme.dim
                font.family: Theme.font
                font.pixelSize: 14
            }
            MouseArea {
                id: mute
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: if (level.node.audio) level.node.audio.muted = !level.muted
            }
        }
        Label {
            visible: level.name !== ""
            Layout.preferredWidth: 96
            text: level.name
            color: Theme.fg
            font.pixelSize: 11
            elide: Text.ElideRight
        }
        Item {
            id: strip
            Layout.fillWidth: true
            implicitHeight: 14

            readonly property int segments: Math.max(1, Math.floor(width / 6))

            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Repeater {
                    model: strip.segments

                    Rectangle {
                        required property int index
                        width: 4
                        height: 10
                        color: !level.muted && index < Math.round(level.volume * strip.segments)
                            ? Theme.accent : Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.15)
                    }
                }
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onPressed: mouse => level.set(mouse.x / width)
                onPositionChanged: mouse => { if (pressed) level.set(mouse.x / width); }
                onWheel: wheel => level.set(level.volume + (wheel.angleDelta.y > 0 ? 0.05 : -0.05))
            }
        }
        Label {
            Layout.preferredWidth: 30
            horizontalAlignment: Text.AlignRight
            text: level.muted ? "MUTE" : String(Math.round(level.volume * 100)).padStart(3, "0")
            color: level.muted ? Theme.muted : Theme.fg
            font.pixelSize: 11
        }
    }
}
