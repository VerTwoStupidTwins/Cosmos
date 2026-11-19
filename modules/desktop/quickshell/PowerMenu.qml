// The power menu: a POWER plate over a dimmed screen with lock, suspend, log out, reboot and shut
// down. Log out, reboot and shut down arm on the first press and act on a second within three
// seconds. Arrows or Tab move, Enter presses, each action's letter presses it, Esc or a click
// outside closes.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: menu

    required property var locker
    property int current: 0
    // The index of the action waiting for its confirming press, or -1.
    property int armed: -1

    readonly property var actions: [
        { key: "L", label: "LOCK", glyph: "󰌾", confirm: false },
        { key: "S", label: "SUSPEND", glyph: "󰒲", confirm: false },
        { key: "E", label: "LOG OUT", glyph: "󰍃", confirm: true },
        { key: "R", label: "REBOOT", glyph: "󰜉", confirm: true },
        { key: "P", label: "SHUT DOWN", glyph: "󰐥", confirm: true }
    ]

    function run(index) {
        switch (actions[index].label) {
        case "LOCK":
            locker.lock();
            break;
        case "SUSPEND":
            // hypridle locks first (before_sleep_cmd).
            Quickshell.execDetached(["systemctl", "suspend"]);
            break;
        case "LOG OUT":
            if (Quickshell.env("NIRI_SOCKET"))
                Quickshell.execDetached(["niri", "msg", "action", "quit", "--skip-confirmation"]);
            else
                Quickshell.execDetached(["loginctl", "terminate-session", Quickshell.env("XDG_SESSION_ID")]);
            break;
        case "REBOOT":
            Quickshell.execDetached(["systemctl", "reboot"]);
            break;
        case "SHUT DOWN":
            Quickshell.execDetached(["systemctl", "poweroff"]);
            break;
        }
    }

    function press(index) {
        current = index;
        if (actions[index].confirm && armed !== index) {
            armed = index;
            disarm.restart();
            return;
        }
        Power.open = false;
        run(index);
    }

    visible: Power.open
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-power"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    color: Qt.rgba(0, 0, 0, 0.55)

    onVisibleChanged: {
        armed = -1;
        current = 0;
        if (visible) keys.forceActiveFocus();
    }

    Timer {
        id: disarm
        interval: 3000
        onTriggered: menu.armed = -1
    }

    MouseArea {
        anchors.fill: parent
        onClicked: Power.open = false
    }

    Item {
        id: keys
        focus: true
        Keys.onPressed: event => {
            const n = menu.actions.length;
            if (event.key === Qt.Key_Escape) {
                Power.open = false;
            } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Backtab) {
                menu.current = (menu.current + n - 1) % n;
            } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab) {
                menu.current = (menu.current + 1) % n;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                menu.press(menu.current);
            } else {
                const i = menu.actions.findIndex(a => a.key === event.text.toUpperCase());
                if (i < 0) return;
                menu.press(i);
            }
            event.accepted = true;
        }
    }

    Plate {
        id: plate
        anchors.centerIn: parent
        title: "POWER"
        status: menu.armed >= 0 ? "PRESS AGAIN TO " + menu.actions[menu.armed].label : Quickshell.env("USER") + "@" + Station.hostname
        statusTone: menu.armed >= 0 ? Theme.urgent : Theme.dim
        cutTopLeft: 6
        cutTopRight: 6
        cutBottomLeft: 14
        cutBottomRight: 14
        padding: 16

        MouseArea {
            parent: plate
            anchors.fill: parent
            z: -1
        }

        RowLayout {
            spacing: 10

            Repeater {
                model: menu.actions

                Item {
                    id: tile

                    required property var modelData
                    required property int index
                    readonly property bool selected: menu.current === index
                    readonly property bool isArmed: menu.armed === index
                    readonly property color tone: isArmed || (selected && modelData.confirm) ? Theme.urgent : Theme.accent

                    implicitWidth: 108
                    implicitHeight: 112

                    PlateShape {
                        anchors.fill: parent
                        cutTopLeft: 10
                        cutBottomRight: 10
                        fillOpacity: tile.selected ? 0.9 : 0.45
                        showStrip: false
                        frameColor: tile.selected ? tile.tone : Qt.rgba(tile.tone.r, tile.tone.g, tile.tone.b, 0.35)
                    }

                    // While armed, a strip drains along the bottom until it disarms.
                    Rectangle {
                        visible: tile.isArmed
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 4
                        x: 8
                        height: 2
                        color: Theme.urgent
                        NumberAnimation on width {
                            running: tile.isArmed
                            from: tile.width - 26
                            to: 0
                            duration: disarm.interval
                        }
                    }

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 8

                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: tile.modelData.glyph
                            color: tile.selected ? tile.tone : Theme.dim
                            font.family: Theme.font
                            font.pixelSize: 30
                        }
                        Label {
                            Layout.alignment: Qt.AlignHCenter
                            text: tile.isArmed ? "CONFIRM" : tile.modelData.label
                            color: tile.selected ? Theme.fg : Theme.dim
                            font.pixelSize: 10
                            font.bold: tile.selected
                            font.letterSpacing: 2
                        }
                        Tag {
                            Layout.alignment: Qt.AlignHCenter
                            text: tile.modelData.key
                            border.color: Qt.rgba(tile.tone.r, tile.tone.g, tile.tone.b, tile.selected ? 0.8 : 0.4)
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: menu.current = tile.index
                        onClicked: menu.press(tile.index)
                    }
                }
            }
        }

        Label {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignRight
            text: "←→ SELECT  ·  ⏎ OR LETTER  ·  ESC CLOSE"
            color: Theme.muted
            font.pixelSize: 9
            font.letterSpacing: 2
        }
    }
}
