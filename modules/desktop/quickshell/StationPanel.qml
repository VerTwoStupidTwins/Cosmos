// The command station: a detailed system overview that drops down below the clock plate. Click
// the clock, or run `qs -c bar ipc call station toggle`, to open and close it; Esc closes it
// once it has focus. Its LAB button swaps it for the homelab page (LabPanel.qml).
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: panel

    visible: Station.open
    anchors.top: true
    margins.top: Tablet.barHeight + 2
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-station"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    color: "transparent"

    implicitWidth: 840
    implicitHeight: content.implicitHeight + 4

    function pad(n, width) {
        return String(Math.round(n)).padStart(width ?? 3, "0");
    }
    function percent(fraction) {
        return pad(fraction * 100) + "%";
    }
    function size(bytes) {
        const units = ["B", "KiB", "MiB", "GiB", "TiB"];
        let i = 0;
        while (bytes >= 1024 && i < units.length - 1) {
            bytes /= 1024;
            i++;
        }
        return (i === 0 ? bytes.toFixed(0) : bytes.toFixed(1)) + " " + units[i];
    }
    function rate(bytes) {
        return size(bytes) + "/s";
    }
    function duration(hours) {
        const h = Math.floor(hours), m = Math.round((hours - h) * 60);
        return h + "h " + String(m).padStart(2, "0") + "m";
    }
    function uptime(seconds) {
        const d = Math.floor(seconds / 86400), h = Math.floor(seconds % 86400 / 3600), m = Math.floor(seconds % 3600 / 60);
        return (d > 0 ? d + "d " : "") + String(h).padStart(2, "0") + "h " + String(m).padStart(2, "0") + "m";
    }
    function temp(c) {
        return c < 0 ? "--" : pad(c) + "°C";
    }
    function heat(c, warm, hot) {
        return c >= hot ? Theme.urgent : c >= warm ? Theme.warn : Theme.fg;
    }
    // Graph values scaled to the busiest moment in view, for counters with no fixed ceiling.
    function scaled(values) {
        const peak = Math.max(1024, ...values);
        return values.map(v => v / peak);
    }

    Item {
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: Station.open = false
    }

    ColumnLayout {
        id: content
        width: parent.width
        spacing: 8
        opacity: 0
        y: -8

        states: State {
            when: panel.visible
            PropertyChanges {
                target: content
                opacity: 1
                y: 0
            }
        }
        transitions: Transition {
            NumberAnimation { properties: "opacity,y"; duration: 160; easing.type: Easing.OutCubic }
        }

        Plate {
            Layout.fillWidth: true
            title: "CMD"
            status: "UP " + panel.uptime(Station.uptime)
            cutTopLeft: 4
            cutTopRight: 4
            cutBottomLeft: 14
            cutBottomRight: 14

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Label {
                    text: Station.hostname.toUpperCase()
                    color: Theme.accent
                    font.pixelSize: 20
                    font.bold: true
                    font.letterSpacing: 3
                }
                Label {
                    text: "// COMMAND STATION"
                    color: Theme.dim
                    font.pixelSize: 11
                    font.letterSpacing: 2
                }
                Item {
                    Layout.fillWidth: true
                }
                Label {
                    // An asterisk marks a build from uncommitted changes.
                    text: [
                        Station.nixos ? "NIXOS " + Station.nixos.split(".").slice(0, 2).join(".") : "",
                        Station.kernel ? "LINUX " + Station.kernel : "",
                        Station.revision ? "REV " + Station.revision.slice(0, 7) + (Station.revision.endsWith("-dirty") ? "*" : "") : ""
                    ].filter(s => s).join("  ·  ")
                    color: Theme.dim
                    font.pixelSize: 11
                    font.letterSpacing: 1
                }
                // The homelab has its own page; this swaps to it.
                Rectangle {
                    visible: Homelab.available
                    implicitWidth: labLabel.implicitWidth + 16
                    implicitHeight: 20
                    color: labPress.containsMouse ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.2) : "transparent"
                    border.width: 1
                    border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.7)

                    Label {
                        id: labLabel
                        anchors.centerIn: parent
                        text: "LAB ▸"
                        color: Theme.accent
                        font.pixelSize: 10
                        font.bold: true
                        font.letterSpacing: 1
                    }
                    MouseArea {
                        id: labPress
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Homelab.show()
                    }
                }
            }
        }

        GridLayout {
            id: grid
            Layout.fillWidth: true
            columns: 2
            columnSpacing: 8
            rowSpacing: 8

            Plate {
                // Equal preferred widths plus fillWidth split the row evenly; without fillWidth
                // the grid can't grow past what its plates ask for, and sits left.
                Layout.preferredWidth: 1
                Layout.fillWidth: true
                Layout.fillHeight: true
                title: "CPU"
                status: panel.percent(Station.cpu)
                statusTone: Station.cpu > 0.85 ? Theme.urgent : Theme.fg

                Sparkline {
                    values: Station.cpuHistory
                    capacity: Station.capacity
                }
                CoreBars {
                    values: Station.cores
                }
                Stat {
                    key: "TEMP"
                    value: panel.temp(Station.cpuTemp)
                    tone: panel.heat(Station.cpuTemp, 75, 90)
                }
                Stat {
                    key: "CLOCK"
                    value: Station.freqGhz.toFixed(2) + " GHz"
                }
                Stat {
                    key: "LOAD"
                    value: Station.load
                }
            }

            Plate {
                // Equal preferred widths plus fillWidth split the row evenly; without fillWidth
                // the grid can't grow past what its plates ask for, and sits left.
                Layout.preferredWidth: 1
                Layout.fillWidth: true
                Layout.fillHeight: true
                title: "MEM"
                status: panel.percent(Station.memTotal ? Station.memUsed / Station.memTotal : 0)
                statusTone: Station.memTotal && Station.memUsed / Station.memTotal > 0.9 ? Theme.urgent : Theme.fg
                stripRight: true

                Sparkline {
                    values: Station.memHistory
                    capacity: Station.capacity
                }
                Gauge {
                    Layout.fillWidth: true
                    // As many 3px segments as fit, so the gauge spans the plate.
                    segments: Math.max(10, Math.floor((parent.width + 2) / 5))
                    value: Station.memTotal ? Station.memUsed / Station.memTotal : 0
                }
                Stat {
                    key: "RAM"
                    value: panel.size(Station.memUsed) + " / " + panel.size(Station.memTotal)
                }
                Stat {
                    key: "SWAP"
                    value: Station.swapTotal ? panel.size(Station.swapUsed) + " / " + panel.size(Station.swapTotal) : "NONE"
                    tone: Station.swapTotal && Station.swapUsed / Station.swapTotal > 0.5 ? Theme.warn : Theme.fg
                }
            }

            Plate {
                visible: Station.gpuBusy >= 0
                // Equal preferred widths plus fillWidth split the row evenly; without fillWidth
                // the grid can't grow past what its plates ask for, and sits left.
                Layout.preferredWidth: 1
                Layout.fillWidth: true
                Layout.fillHeight: true
                title: "GPU"
                status: panel.percent(Math.max(0, Station.gpuBusy))

                Sparkline {
                    values: Station.gpuHistory
                    capacity: Station.capacity
                }
                Stat {
                    key: "VRAM"
                    value: panel.size(Station.vramUsed) + " / " + panel.size(Station.vramTotal)
                }
                Stat {
                    key: "TEMP"
                    value: panel.temp(Station.gpuTemp)
                    tone: panel.heat(Station.gpuTemp, 80, 95)
                }
            }

            Plate {
                visible: Station.battery >= 0
                // Equal preferred widths plus fillWidth split the row evenly; without fillWidth
                // the grid can't grow past what its plates ask for, and sits left.
                Layout.preferredWidth: 1
                Layout.fillWidth: true
                Layout.fillHeight: true
                title: "PWR"
                status: panel.pad(Station.battery) + "%"
                statusTone: Station.batteryStatus === "Charging" ? Theme.good
                    : Station.battery <= 10 ? Theme.urgent : Station.battery <= 25 ? Theme.warn : Theme.fg
                stripRight: true

                Gauge {
                    Layout.fillWidth: true
                    // As many 3px segments as fit, so the gauge spans the plate.
                    segments: Math.max(10, Math.floor((parent.width + 2) / 5))
                    value: Station.battery / 100
                    color: Station.batteryStatus === "Charging" ? Theme.good
                        : Station.battery <= 10 ? Theme.urgent : Station.battery <= 25 ? Theme.warn : Theme.accent
                }
                Stat {
                    key: "STATE"
                    value: Station.batteryStatus.toUpperCase()
                }
                Stat {
                    key: "DRAW"
                    value: Station.watts.toFixed(1) + " W"
                }
                Stat {
                    key: Station.batteryStatus === "Charging" ? "TO FULL" : "REMAINING"
                    value: Station.hoursLeft >= 0 ? panel.duration(Station.hoursLeft) : "--"
                }
            }

            Plate {
                // Equal preferred widths plus fillWidth split the row evenly; without fillWidth
                // the grid can't grow past what its plates ask for, and sits left.
                Layout.preferredWidth: 1
                Layout.fillWidth: true
                Layout.fillHeight: true
                title: "NET"
                status: Station.netDevice ? Station.netDevice.toUpperCase() : "NO ROUTE"
                statusTone: Station.netDevice ? Theme.fg : Theme.urgent

                Sparkline {
                    values: panel.scaled(Station.rxHistory)
                    capacity: Station.capacity
                    implicitHeight: 24
                }
                Sparkline {
                    values: panel.scaled(Station.txHistory)
                    capacity: Station.capacity
                    color: Theme.good
                    implicitHeight: 24
                }
                Stat {
                    key: "DOWN"
                    value: panel.rate(Station.rxRate)
                }
                Stat {
                    key: "UP"
                    value: panel.rate(Station.txRate)
                    tone: Theme.good
                }
                Repeater {
                    model: Object.keys(Station.addresses)

                    Stat {
                        required property string modelData
                        key: modelData.startsWith("nb-") ? "MESH" : modelData.toUpperCase()
                        value: Station.addresses[modelData]
                    }
                }
            }

            Plate {
                // Equal preferred widths plus fillWidth split the row evenly; without fillWidth
                // the grid can't grow past what its plates ask for, and sits left.
                Layout.preferredWidth: 1
                Layout.fillWidth: true
                Layout.fillHeight: true
                title: "DSK"
                status: Station.nvmeTemp >= 0 ? "NVME " + panel.temp(Station.nvmeTemp) : ""
                statusTone: panel.heat(Station.nvmeTemp, 60, 70)
                stripRight: true

                Repeater {
                    model: Station.disks

                    ColumnLayout {
                        required property var modelData
                        readonly property real used: modelData.size ? modelData.used / modelData.size : 0

                        Layout.fillWidth: true
                        spacing: 4

                        Stat {
                            key: parent.modelData.mount.toUpperCase()
                            value: panel.size(parent.modelData.used) + " / " + panel.size(parent.modelData.size)
                            tone: parent.used >= 0.95 ? Theme.urgent : parent.used >= 0.85 ? Theme.warn : Theme.fg
                        }
                        Gauge {
                            Layout.fillWidth: true
                            // As many 3px segments as fit, so the gauge spans the plate.
                    segments: Math.max(10, Math.floor((parent.width + 2) / 5))
                            value: parent.used
                            color: parent.used >= 0.95 ? Theme.urgent : parent.used >= 0.85 ? Theme.warn : Theme.accent
                        }
                    }
                }
            }
        }
    }
}
