// The network plate: rises over the bottom bar's right plate when COM is clicked. Wi-Fi on/off,
// the wired link if there is one, and the Wi-Fi networks in range: connected first, then known
// ones, then by signal. A click connects (asking for the password when the network needs one it
// doesn't have) or disconnects; a known network's × forgets it. Esc closes.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Networking

PanelWindow {
    id: panel

    readonly property var devices: Array.from(Networking.devices.values)
    readonly property var wifi: devices.find(d => d.type === DeviceType.Wifi) ?? null
    readonly property var wired: devices.find(d => d.type === DeviceType.Wired) ?? null
    readonly property var networks: {
        if (!wifi || !Networking.wifiEnabled) return [];
        const seen = new Set();
        return Array.from(wifi.networks.values)
            .filter(n => n.name && !seen.has(n.name) && seen.add(n.name))
            .sort((a, b) => (b.connected - a.connected) || (b.known - a.known) || (b.signalStrength - a.signalStrength));
    }
    // The network asking for a password, and the last failure per network name.
    property var asking: null
    property var failures: ({})

    readonly property string connectivity: {
        switch (Networking.connectivity) {
        case NetworkConnectivity.Full: return "ONLINE";
        case NetworkConnectivity.Limited: return "LIMITED";
        case NetworkConnectivity.Portal: return "LOGIN PAGE";
        case NetworkConnectivity.None: return "OFFLINE";
        default: return "";
        }
    }

    function press(network) {
        failures = Object.assign({}, failures, { [network.name]: "" });
        if (network.connected) {
            network.disconnect();
        } else if (network.known || network.security === WifiSecurityType.Open || network.security === WifiSecurityType.Owe) {
            network.connect();
        } else {
            asking = network;
        }
    }

    function fail(network, reason) {
        const text = {
            [ConnectionFailReason.NoSecrets]: "NEEDS PASSWORD",
            [ConnectionFailReason.WifiClientDisconnected]: "DISCONNECTED",
            [ConnectionFailReason.WifiClientFailed]: "WRONG PASSWORD?",
            [ConnectionFailReason.WifiAuthTimeout]: "TIMED OUT",
            [ConnectionFailReason.WifiNetworkLost]: "OUT OF RANGE"
        }[reason] ?? "FAILED";
        failures = Object.assign({}, failures, { [network.name]: text });
        if (reason === ConnectionFailReason.NoSecrets || reason === ConnectionFailReason.WifiClientFailed) asking = network;
    }

    visible: Panels.open === "network"
    anchors.bottom: true
    anchors.right: true
    margins.bottom: Tablet.barHeight + 2
    margins.right: 8
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-network"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    color: "transparent"

    implicitWidth: 380
    implicitHeight: plate.implicitHeight + 4

    onVisibleChanged: {
        asking = null;
        if (visible) keys.forceActiveFocus();
    }

    // Scan while the plate is open, so the list is current.
    Binding {
        target: panel.wifi
        property: "scannerEnabled"
        value: panel.visible
        when: panel.wifi !== null
    }

    Item {
        id: keys
        focus: true
        Keys.onEscapePressed: Panels.open = ""
    }

    Plate {
        id: plate
        width: parent.width
        anchors.bottom: parent.bottom
        title: "COM"
        status: panel.connectivity
        statusTone: Networking.connectivity === NetworkConnectivity.Full ? Theme.good
            : Networking.connectivity === NetworkConnectivity.None ? Theme.urgent : Theme.warn
        cutTopLeft: 14
        cutBottomRight: 4
        cutBottomLeft: 10
        stripRight: true
        padding: 14

        // Wi-Fi on/off, and NetworkManager's own TUI for everything else.
        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            PanelButton {
                text: Networking.wifiEnabled ? "WIFI ON" : "WIFI OFF"
                lit: Networking.wifiEnabled
                enabled: Networking.wifiHardwareEnabled
                onClicked: Networking.wifiEnabled = !Networking.wifiEnabled
            }
            Label {
                visible: !Networking.wifiHardwareEnabled
                text: "RADIO SWITCHED OFF"
                color: Theme.warn
                font.pixelSize: 9
                font.letterSpacing: 1
            }
            Item {
                Layout.fillWidth: true
            }
            PanelButton {
                text: "SETTINGS"
                onClicked: {
                    Quickshell.execDetached([Config.systemdRun, "--user", "--scope", "--collect", "--quiet", "--slice=app.slice", "--", Config.terminal, "-e", "nmtui"]);
                    Panels.open = "";
                }
            }
        }

        // The wired link, when there's a port for one.
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 4
            visible: panel.wired !== null
            spacing: 8

            Tag {
                text: "ETH"
            }
            Label {
                Layout.fillWidth: true
                text: panel.wired?.connected ? "CONNECTED" + (panel.wired.linkSpeed ? " · " + panel.wired.linkSpeed + " MB/S" : "")
                    : panel.wired?.hasLink ? "CABLE IN, NOT CONNECTED" : "NO CABLE"
                color: panel.wired?.connected ? Theme.fg : Theme.muted
                font.pixelSize: 11
            }
        }

        Label {
            Layout.topMargin: 4
            visible: panel.wifi !== null && Networking.wifiEnabled
            text: "NETWORKS IN RANGE · " + String(panel.networks.length).padStart(2, "0")
            color: Theme.muted
            font.pixelSize: 9
            font.letterSpacing: 2
        }

        ListView {
            id: list
            Layout.fillWidth: true
            implicitHeight: Math.min(contentHeight, 360)
            visible: panel.networks.length > 0
            clip: true
            spacing: 4
            boundsBehavior: Flickable.StopAtBounds
            model: panel.networks

            delegate: Item {
                id: row

                required property var modelData
                readonly property var network: modelData
                readonly property bool secured: network.security !== WifiSecurityType.Open && network.security !== WifiSecurityType.Owe
                readonly property bool busy: network.stateChanging || network.state === ConnectionState.Connecting
                readonly property string failure: panel.failures[network.name] ?? ""
                readonly property bool askingHere: panel.asking === network

                width: list.width
                height: line.height + (askingHere ? password.height + 6 : 0)

                Connections {
                    target: row.network
                    function onConnectionFailed(reason) { panel.fail(row.network, reason); }
                    function onConnectedChanged() {
                        if (row.network.connected && panel.asking === row.network) panel.asking = null;
                    }
                }

                HoverHandler {
                    id: hover
                }

                Item {
                    id: line
                    width: parent.width
                    height: 34

                    PlateShape {
                        anchors.fill: parent
                        cutTopLeft: 6
                        cutBottomRight: 6
                        fillOpacity: row.network.connected ? 0.8 : hover.hovered ? 0.6 : 0.3
                        showStrip: false
                        frameColor: row.network.connected ? Theme.accent : Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, hover.hovered ? 0.5 : 0.2)
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 8

                        Gauge {
                            Layout.alignment: Qt.AlignVCenter
                            segments: 4
                            value: row.network.signalStrength
                            color: row.network.connected ? Theme.accent : Theme.dim
                        }
                        Label {
                            Layout.fillWidth: true
                            text: row.network.name
                            color: row.network.connected ? Theme.fg : Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.85)
                            font.pixelSize: 12
                            font.bold: row.network.connected
                            elide: Text.ElideRight
                        }
                        Label {
                            text: row.failure !== "" ? row.failure
                                : row.busy ? (row.network.connected ? "DISCONNECTING" : "CONNECTING")
                                : row.network.connected ? "LINKED" : row.network.known ? "KNOWN" : ""
                            visible: text !== ""
                            color: row.failure !== "" ? Theme.urgent : row.busy ? Theme.warn : row.network.connected ? Theme.good : Theme.muted
                            font.pixelSize: 9
                            font.letterSpacing: 1
                        }
                        Text {
                            visible: row.secured
                            text: "󰌾"
                            color: Theme.muted
                            font.family: Theme.font
                            font.pixelSize: 11
                        }
                        // Forget a known network.
                        Text {
                            visible: row.network.known && hover.hovered
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
                                onClicked: row.network.forget()
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        z: -1
                        cursorShape: Qt.PointingHandCursor
                        onClicked: panel.press(row.network)
                    }
                }

                // The password, for a network that needs one.
                Item {
                    id: password
                    visible: row.askingHere
                    y: line.height + 6
                    width: parent.width
                    height: 32

                    PlateShape {
                        anchors.fill: parent
                        cutTopLeft: 6
                        cutBottomRight: 6
                        fillOpacity: 0.55
                        showStrip: false
                    }
                    Label {
                        id: keyLabel
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: "KEY"
                        color: Theme.accent
                        font.pixelSize: 9
                        font.bold: true
                        font.letterSpacing: 2
                    }
                    TextInput {
                        id: psk
                        anchors.left: keyLabel.right
                        anchors.leftMargin: 10
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        echoMode: TextInput.Password
                        passwordCharacter: "•"
                        color: Theme.fg
                        font.family: Theme.font
                        font.pixelSize: 13
                        clip: true

                        onVisibleChanged: {
                            text = "";
                            if (visible) forceActiveFocus();
                        }
                        onAccepted: {
                            if (text.length === 0) return;
                            row.network.connectWithPsk(text);
                            text = "";
                        }
                        Keys.onEscapePressed: panel.asking = null
                    }
                }
            }
        }

        Label {
            Layout.fillWidth: true
            visible: panel.wifi !== null && Networking.wifiEnabled && panel.networks.length === 0
            text: "SCANNING…"
            color: Theme.muted
            font.pixelSize: 10
            font.letterSpacing: 3
            horizontalAlignment: Text.AlignHCenter
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
