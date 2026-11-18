// The command station: a detailed system overview that drops down below the clock plate. Click
// the clock, or run `qs -c bar ipc call station toggle`, to open and close it; Esc closes it
// once it has focus.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: panel

    visible: Station.open
    anchors.top: true
    margins.top: 42
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

        // The homelab: each lab host's monitor, checked while the station is open (Homelab.qml).
        Plate {
            Layout.fillWidth: true
            visible: Homelab.available
            title: "LAB"
            status: Homelab.checking ? "CHECKING…"
                : Homelab.checkedAt.getTime() > 0 ? "CHECKED " + Qt.formatTime(Homelab.checkedAt, "HH:mm") : ""
            statusTone: Theme.dim
            cutTopLeft: 4
            cutTopRight: 14
            cutBottomLeft: 14
            cutBottomRight: 4

            Label {
                visible: Homelab.hosts.length === 0
                text: Homelab.checking ? "ASKING THE LAB…" : "NO REPORT YET"
                color: Theme.muted
                font.pixelSize: 10
                font.letterSpacing: 3
            }

            Repeater {
                model: Homelab.hosts

                LabHost {
                    required property var modelData
                    required property int index
                    entry: modelData
                    first: index === 0
                }
            }
        }
    }

    component LabHost: ColumnLayout {
        id: host

        required property var entry
        property bool first: false
        readonly property var r: entry.report ?? null
        readonly property var sys: r?.system ?? ({})
        readonly property var warnings: r?.warnings ?? []
        readonly property real cpuTemp: hottest(sys.cpu_temps_c)
        readonly property real memUsed: sys.memory ? 100 - sys.memory.available_percent : -1
        readonly property real diskUsed: sys.disks?.["/"]?.used_percent ?? -1
        readonly property var models: r?.models?.loaded ? Object.values(r.models.loaded) : []
        readonly property string state: !r ? "DOWN" : r.status === "ok" ? "OK" : "ATTN"
        readonly property color tone: state === "OK" ? Theme.good : state === "ATTN" ? Theme.warn : Theme.urgent

        function hottest(temps) {
            return temps ? Math.max(-1, ...Object.values(temps)) : -1;
        }
        // Why SSH didn't get a report, in a word.
        function reason(error) {
            if (/Permission denied/.test(error)) return "ACCESS DENIED";
            if (/resolve/i.test(error)) return "NOT ON THE MESH";
            if (/timed out|No route|refused|closed|reset/i.test(error)) return "UNREACHABLE";
            return "NO ANSWER";
        }

        Layout.fillWidth: true
        spacing: 5

        Rectangle {
            visible: !host.first
            Layout.fillWidth: true
            Layout.topMargin: 2
            Layout.bottomMargin: 2
            implicitHeight: 1
            color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            Label {
                text: host.entry.host.toUpperCase()
                color: Theme.accent
                font.pixelSize: 15
                font.bold: true
                font.letterSpacing: 3
            }
            Rectangle {
                implicitWidth: stateLabel.implicitWidth + 10
                implicitHeight: 15
                color: Qt.rgba(host.tone.r, host.tone.g, host.tone.b, 0.15)
                border.width: 1
                border.color: host.tone

                Label {
                    id: stateLabel
                    anchors.centerIn: parent
                    text: host.state
                    color: host.tone
                    font.pixelSize: 9
                    font.bold: true
                    font.letterSpacing: 1.5
                }
            }
            Label {
                visible: !host.r
                Layout.fillWidth: true
                text: host.reason(host.entry.error ?? "") + "  ·  " + (host.entry.error ?? "")
                color: Theme.dim
                font.pixelSize: 10
                elide: Text.ElideRight
            }
            Item {
                visible: !!host.r
                Layout.fillWidth: true
            }
            Label {
                visible: !!host.r
                text: [
                    host.models.length ? "MODELS " + host.models.filter(m => m === "ready").length + "/" + host.models.length : "",
                    host.sys.last_rebuild?.revision ? "REV " + host.sys.last_rebuild.revision.slice(0, 7) : "",
                    host.sys.uptime_days !== undefined ? "UP " + host.sys.uptime_days.toFixed(1) + "D" : ""
                ].filter(s => s).join("  ·  ")
                color: Theme.dim
                font.pixelSize: 10
                font.letterSpacing: 1
            }
        }

        // Readings: CPU, memory, root disk, and each GPU's memory and temperature.
        Flow {
            visible: !!host.r
            Layout.fillWidth: true
            spacing: 12

            Reading {
                key: "CPU"
                value: panel.temp(host.cpuTemp)
                tone: panel.heat(host.cpuTemp, 75, 90)
            }
            Reading {
                key: "MEM"
                value: host.memUsed >= 0 ? panel.pad(host.memUsed) + "%" : "--"
                fraction: host.memUsed / 100
            }
            Reading {
                key: "DSK"
                value: host.diskUsed >= 0 ? panel.pad(host.diskUsed) + "%" : "--"
                fraction: host.diskUsed / 100
            }
            Repeater {
                model: host.r?.gpus ?? []

                Reading {
                    required property var modelData
                    readonly property real used: modelData.vram_total_mib ? 1 - modelData.vram_free_mib / modelData.vram_total_mib : -1

                    key: modelData.short.toUpperCase()
                    value: used >= 0 ? panel.pad(used * 100) + "%  " + panel.temp(host.hottest(modelData.temps_c)) : "--"
                    fraction: used
                    tone: panel.heat(host.hottest(modelData.temps_c), 80, 95)
                }
            }
        }

        // What needs looking at, as the monitor words it.
        Repeater {
            model: host.warnings.slice(0, 2)

            Label {
                required property string modelData
                Layout.fillWidth: true
                text: "▲ " + modelData
                color: Theme.warn
                font.pixelSize: 10
                elide: Text.ElideRight
            }
        }
        Label {
            visible: host.warnings.length > 2
            text: "+" + (host.warnings.length - 2) + " MORE"
            color: Theme.muted
            font.pixelSize: 9
            font.letterSpacing: 2
        }
    }

    // A key, its value, and a small gauge when it's a fraction.
    component Reading: Row {
        property string key
        property string value
        property real fraction: -1
        property color tone: Theme.fg

        spacing: 6

        Label {
            anchors.verticalCenter: parent.verticalCenter
            text: parent.key
            color: Theme.muted
            font.pixelSize: 9
            font.letterSpacing: 1.5
        }
        Gauge {
            visible: parent.fraction >= 0
            anchors.verticalCenter: parent.verticalCenter
            segments: 6
            value: Math.max(0, parent.fraction)
            color: parent.fraction >= 0.95 ? Theme.urgent : parent.fraction >= 0.85 ? Theme.warn : Theme.accent
        }
        Label {
            anchors.verticalCenter: parent.verticalCenter
            text: parent.value
            color: parent.tone
            font.pixelSize: 11
        }
    }
}
