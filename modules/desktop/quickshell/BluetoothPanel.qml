// The Bluetooth plate: rises over the bottom bar's right plate when BT is clicked. Bluetooth on/off,
// paired devices (connected first) with their battery where they report it, and devices nearby,
// found by scanning while the plate is open. A click connects or disconnects a paired device, or
// pairs a nearby one (then trusts and connects it); a paired device's × forgets it. Devices that
// need a PIN typed have no agent here: SETTINGS opens bluetoothctl for those. Esc closes.
// It closes itself after a few seconds (Panels.idleClose) without the pointer over it.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Bluetooth

PanelWindow {
    id: panel

    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property bool on: adapter?.enabled ?? false
    readonly property var devices: adapter ? Array.from(adapter.devices.values) : []
    readonly property var paired: devices.filter(d => d.paired)
        .sort((a, b) => (b.connected - a.connected) || a.name.localeCompare(b.name))
    // Nearby devices with a name; unnamed ones are mostly beacons and phones' randomised addresses.
    readonly property var nearby: devices.filter(d => !d.paired && d.deviceName !== "")
        .sort((a, b) => a.name.localeCompare(b.name))

    function glyph(icon) {
        if (icon.includes("headset") || icon.includes("headphone")) return "󰋋";
        if (icon.includes("audio")) return "󰓃";
        if (icon.includes("keyboard")) return "󰌌";
        if (icon.includes("mouse")) return "󰍽";
        if (icon.includes("phone")) return "󰏲";
        if (icon.includes("gaming") || icon.includes("joystick")) return "󰊴";
        if (icon.includes("computer")) return "󰟀";
        return "󰂯";
    }

    function press(device) {
        if (device.paired) {
            device.connected = !device.connected;
        } else if (!device.pairing) {
            device.pair();
        }
    }

    visible: Panels.open === "bluetooth"
    anchors.bottom: true
    anchors.right: true
    margins.bottom: Tablet.barHeight + 2
    margins.right: 8
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-bluetooth"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    color: "transparent"

    implicitWidth: 380
    implicitHeight: plate.implicitHeight + 4

    onVisibleChanged: if (visible) keys.forceActiveFocus()

    // Scan while the plate is open.
    Binding {
        target: panel.adapter
        property: "discovering"
        value: panel.visible && panel.on
        when: panel.adapter !== null
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
        title: "BT"
        status: !panel.adapter ? "NO ADAPTER" : !panel.on ? "OFF"
            : panel.adapter.discovering ? "SCANNING" : "ON"
        statusTone: panel.on ? Theme.good : Theme.muted
        cutTopLeft: 14
        cutBottomRight: 4
        cutBottomLeft: 10
        stripRight: true
        padding: 14

        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            PanelButton {
                text: panel.on ? "BT ON" : "BT OFF"
                lit: panel.on
                enabled: panel.adapter !== null
                onClicked: panel.adapter.enabled = !panel.on
            }
            Item {
                Layout.fillWidth: true
            }
            PanelButton {
                text: "SETTINGS"
                onClicked: {
                    Quickshell.execDetached([Config.systemdRun, "--user", "--scope", "--collect", "--quiet", "--slice=app.slice", "--", Config.terminal, "-e", "bluetoothctl"]);
                    Panels.open = "";
                }
            }
        }

        Section {
            text: "PAIRED · " + String(panel.paired.length).padStart(2, "0")
            visible: panel.on
        }
        Repeater {
            model: panel.on ? panel.paired : []

            DeviceRow {
                required property var modelData
                device: modelData
            }
        }

        Section {
            text: "NEARBY · " + String(panel.nearby.length).padStart(2, "0")
            visible: panel.on
        }
        ListView {
            Layout.fillWidth: true
            implicitHeight: Math.min(contentHeight, 200)
            visible: panel.on && panel.nearby.length > 0
            clip: true
            spacing: 4
            boundsBehavior: Flickable.StopAtBounds
            model: panel.nearby

            delegate: DeviceRow {
                required property var modelData
                width: ListView.view.width
                device: modelData
            }
        }
        Label {
            Layout.fillWidth: true
            visible: panel.on && panel.nearby.length === 0
            text: "SEARCHING…"
            color: Theme.muted
            font.pixelSize: 10
            font.letterSpacing: 3
            horizontalAlignment: Text.AlignHCenter
        }
    }

    component Section: Label {
        Layout.topMargin: 6
        color: Theme.muted
        font.pixelSize: 9
        font.letterSpacing: 2
    }

    component DeviceRow: Item {
        id: row

        required property var device
        readonly property bool busy: device.pairing || device.state === BluetoothDeviceState.Connecting
            || device.state === BluetoothDeviceState.Disconnecting

        Layout.fillWidth: true
        implicitHeight: 34

        // Once paired, trust it (so it reconnects by itself) and connect.
        Connections {
            target: row.device
            function onPairedChanged() {
                if (!row.device.paired) return;
                row.device.trusted = true;
                row.device.connected = true;
            }
        }

        HoverHandler {
            id: hover
        }
        PlateShape {
            anchors.fill: parent
            cutTopLeft: 6
            cutBottomRight: 6
            fillOpacity: row.device.connected ? 0.8 : hover.hovered ? 0.6 : 0.3
            showStrip: false
            frameColor: row.device.connected ? Theme.accent : Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, hover.hovered ? 0.5 : 0.2)
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: panel.press(row.device)
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 8

            Text {
                text: panel.glyph(row.device.icon)
                color: row.device.connected ? Theme.accent : Theme.dim
                font.family: Theme.font
                font.pixelSize: 14
            }
            Label {
                Layout.fillWidth: true
                text: row.device.name || row.device.address
                color: row.device.connected ? Theme.fg : Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.85)
                font.pixelSize: 12
                font.bold: row.device.connected
                elide: Text.ElideRight
            }
            // Battery, where the device reports it.
            Gauge {
                visible: row.device.batteryAvailable
                Layout.alignment: Qt.AlignVCenter
                segments: 5
                value: row.device.battery
                color: row.device.battery <= 0.2 ? Theme.urgent : Theme.accent
            }
            Label {
                visible: row.device.batteryAvailable
                text: String(Math.round(row.device.battery * 100)).padStart(3, "0")
                color: Theme.dim
                font.pixelSize: 10
            }
            Label {
                text: row.device.pairing ? "PAIRING" : row.busy ? (row.device.connected ? "DISCONNECTING" : "CONNECTING")
                    : row.device.connected ? "LINKED" : row.device.paired ? "" : "PAIR"
                visible: text !== ""
                color: row.busy ? Theme.warn : row.device.connected ? Theme.good : Theme.muted
                font.pixelSize: 9
                font.letterSpacing: 1
            }
            Text {
                visible: row.device.paired && hover.hovered
                text: "×"
                color: forget.containsMouse ? Theme.urgent : Theme.muted
                font.family: Theme.font
                font.pixelSize: 14

                MouseArea {
                    id: forget
                    anchors.fill: parent
                    anchors.margins: -4
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: row.device.forget()
                }
            }
        }
    }

    component PanelButton: Rectangle {
        id: button

        property alias text: label.text
        property bool lit: false
        signal clicked

        implicitWidth: label.implicitWidth + 16
        implicitHeight: 20
        opacity: enabled ? 1 : 0.4
        color: lit || press.containsMouse ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.2) : "transparent"
        border.width: 1
        border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.7)

        Label {
            id: label
            anchors.centerIn: parent
            color: Theme.accent
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
