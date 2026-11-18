// The homelab page: drops down below the clock plate like the command station, with a card per lab
// host from its monitor's health report (Homelab.qml). Each card has the host's state, build,
// system readings, disks, GPUs, models, services, hardware health, config drift and the monitor's
// warnings; a host that didn't answer says why. Two columns once there's more than one host,
// scrolling when they don't fit. Open it with the station's LAB button, Mod+B, or
// `qs -c bar ipc call lab toggle`; Esc closes, R checks again.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: panel

    visible: Homelab.open
    anchors.top: true
    margins.top: 42
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-lab"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    color: "transparent"

    implicitWidth: 960
    implicitHeight: content.implicitHeight + 4

    function pad(n, width) {
        return String(Math.round(n)).padStart(width ?? 3, "0");
    }
    function temp(c) {
        return c < 0 ? "--" : pad(c) + "°C";
    }
    function heat(c, warm, hot) {
        return c >= hot ? Theme.urgent : c >= warm ? Theme.warn : Theme.fg;
    }
    function fill(fraction) {
        return fraction >= 0.95 ? Theme.urgent : fraction >= 0.85 ? Theme.warn : Theme.accent;
    }
    function hottest(temps) {
        return temps ? Math.max(-1, ...Object.values(temps)) : -1;
    }
    function gib(n) {
        return n >= 1000 ? (n / 1024).toFixed(1) + "T" : n >= 100 ? Math.round(n) + "G" : n.toFixed(1) + "G";
    }

    onVisibleChanged: if (visible) keys.forceActiveFocus()

    Item {
        id: keys
        focus: true
        Keys.onEscapePressed: Homelab.open = false
        Keys.onPressed: event => {
            if (event.key === Qt.Key_R) Homelab.check();
        }
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
            title: "LAB"
            status: Homelab.checking ? "CHECKING…"
                : Homelab.checkedAt.getTime() > 0 ? "CHECKED " + Qt.formatTime(Homelab.checkedAt, "HH:mm") : ""
            statusTone: Homelab.checking ? Theme.warn : Theme.dim
            cutTopLeft: 4
            cutTopRight: 4
            cutBottomLeft: 14
            cutBottomRight: 14

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Label {
                    text: "HOMELAB"
                    color: Theme.accent
                    font.pixelSize: 20
                    font.bold: true
                    font.letterSpacing: 3
                }
                Label {
                    text: "// " + String(Homelab.hosts.length).padStart(2, "0") + " HOSTS"
                    color: Theme.dim
                    font.pixelSize: 11
                    font.letterSpacing: 2
                }
                Item {
                    Layout.fillWidth: true
                }
                Label {
                    visible: Homelab.hosts.length > 0
                    text: String(Homelab.healthy).padStart(2, "0") + " OK"
                        + (Homelab.hosts.length > Homelab.healthy ? "  ·  " + String(Homelab.hosts.length - Homelab.healthy).padStart(2, "0") + " NEED A LOOK" : "")
                    color: Homelab.healthy === Homelab.hosts.length ? Theme.good : Theme.warn
                    font.pixelSize: 11
                    font.letterSpacing: 1
                }
                PageButton {
                    text: "CHECK"
                    enabled: !Homelab.checking
                    onClicked: Homelab.check()
                }
                PageButton {
                    text: "◂ CMD"
                    onClicked: Station.open = true
                }
            }
        }

        Label {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 8
            visible: Homelab.hosts.length === 0
            text: Homelab.checking ? "ASKING THE LAB…" : "NO REPORT YET"
            color: Theme.muted
            font.pixelSize: 10
            font.letterSpacing: 3
        }

        Flickable {
            Layout.fillWidth: true
            // Scroll once the cards are taller than the screen leaves room for.
            implicitHeight: Math.min(grid.implicitHeight, (panel.screen?.height ?? 1080) - 160)
            contentHeight: grid.implicitHeight
            visible: Homelab.hosts.length > 0
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            GridLayout {
                id: grid
                width: parent.width
                columns: Homelab.hosts.length > 1 ? 2 : 1
                columnSpacing: 8
                rowSpacing: 8

                Repeater {
                    model: Homelab.hosts

                    HostCard {
                        required property var modelData
                        required property int index
                        entry: modelData
                        // Corners alternate across the columns, like the station's plates.
                        mirrored: grid.columns === 2 && index % 2 === 1
                    }
                }
            }
        }
    }

    component HostCard: Plate {
        id: card

        required property var entry
        property bool mirrored: false
        readonly property var r: entry.report ?? null
        readonly property var sys: r?.system ?? ({})
        readonly property var hw: r?.hardware ?? ({})
        readonly property var build: sys.last_rebuild ?? null
        readonly property var warnings: r?.warnings ?? []
        readonly property string health: !r ? "DOWN" : r.status === "ok" ? "OK" : "ATTN"
        readonly property color tone: health === "OK" ? Theme.good : health === "ATTN" ? Theme.warn : Theme.urgent
        readonly property real memUsed: sys.memory ? 1 - sys.memory.available_percent / 100 : -1
        readonly property real load: sys.load_average && sys.cpu_threads ? sys.load_average[0] / sys.cpu_threads : -1
        readonly property var disks: Object.entries(sys.disks ?? {})
        readonly property var models: Object.entries(r?.models?.loaded ?? {})
        readonly property var missingModels: r?.models?.missing_always_loaded ?? []
        readonly property var services: Object.entries(r?.services?.services ?? {})
        readonly property var failedUnits: r?.services?.failed_units ?? []
        readonly property var nvme: Object.entries(hw.nvme ?? {})
        readonly property int btrfsErrors: Object.values(hw.btrfs_errors ?? {})
            .reduce((n, dev) => n + Object.values(dev).reduce((a, b) => a + b, 0), 0)
        readonly property int kernelIssues: Object.keys(hw.kernel_this_boot ?? {}).length
        // What config_drift found out of place: ports not listening, MCP servers not running, cards
        // out of order.
        readonly property var drift: {
            const d = r?.config_drift ?? {};
            const out = [];
            for (const [name, p] of Object.entries(d.ports ?? {}))
                if (!p.listening) out.push(name.toUpperCase() + " :" + p.port + " NOT LISTENING");
            for (const [name, m] of Object.entries(d.mcp_servers ?? {}))
                if (!m.running) out.push("MCP " + name.toUpperCase() + " DOWN");
            if (d.card_order?.checked && !d.card_order.ok) out.push("GPU ORDER CHANGED");
            return out;
        }
        readonly property bool hasDrift: r?.config_drift !== undefined

        // Why SSH didn't get a report, in a word.
        function reason(error) {
            if (/Permission denied/.test(error)) return "ACCESS DENIED";
            if (/resolve/i.test(error)) return "NOT ON THE MESH";
            if (/timed out|No route|refused|closed|reset/i.test(error)) return "UNREACHABLE";
            return "NO ANSWER";
        }

        Layout.preferredWidth: 1
        Layout.fillWidth: true
        // A host that didn't answer has two lines to show; it doesn't stretch to its neighbour.
        Layout.fillHeight: !!r
        Layout.alignment: Qt.AlignTop
        title: entry.host.toUpperCase()
        status: health
        statusTone: tone
        cutTopLeft: mirrored ? 0 : 4
        cutTopRight: mirrored ? 4 : 0
        cutBottomLeft: mirrored ? 0 : 14
        cutBottomRight: mirrored ? 14 : 0
        stripRight: mirrored

        // Down: why, and what SSH said.
        Label {
            visible: !card.r
            Layout.fillWidth: true
            text: card.reason(card.entry.error ?? "")
            color: Theme.urgent
            font.pixelSize: 13
            font.bold: true
            font.letterSpacing: 2
        }
        Label {
            visible: !card.r
            Layout.fillWidth: true
            text: card.entry.error ?? ""
            color: Theme.dim
            font.pixelSize: 10
            wrapMode: Text.Wrap
        }

        // Up: uptime, build, and whether what's running is what was last built.
        ColumnLayout {
            visible: !!card.r
            Layout.fillWidth: true
            spacing: 6

            Stat {
                key: "UPTIME"
                value: card.sys.uptime_days !== undefined ? card.sys.uptime_days.toFixed(1) + " DAYS"
                    + (card.hw.previous_boot && !card.hw.previous_boot.ended_cleanly ? "  ·  LAST BOOT CRASHED" : "") : "--"
                tone: card.hw.previous_boot && !card.hw.previous_boot.ended_cleanly ? Theme.warn : Theme.fg
            }
            Stat {
                key: "BUILD"
                value: !card.build ? "--" : [
                    card.build.revision ? card.build.revision.slice(0, 7) : "",
                    card.build.uncommitted_changes ? "DIRTY" : "",
                    card.build.running_matches_latest === false ? "NOT RUNNING LATEST" : "",
                    card.build.at ?? ""
                ].filter(s => s).join("  ·  ")
                tone: card.build && (card.build.uncommitted_changes || card.build.running_matches_latest === false) ? Theme.warn : Theme.fg
            }

            // Readings: CPU, load, memory, swap and NVMe temperature.
            Flow {
                Layout.fillWidth: true
                Layout.topMargin: 2
                spacing: 14

                Reading {
                    key: "CPU"
                    value: panel.temp(panel.hottest(card.sys.cpu_temps_c))
                    tone: panel.heat(panel.hottest(card.sys.cpu_temps_c), 75, 90)
                }
                Reading {
                    key: "LOAD"
                    value: card.sys.load_average ? card.sys.load_average[0].toFixed(2) : "--"
                    fraction: Math.min(1, card.load)
                }
                Reading {
                    key: "MEM"
                    value: card.sys.memory ? panel.gib(card.sys.memory.total_gib - card.sys.memory.available_gib) + "/" + panel.gib(card.sys.memory.total_gib) : "--"
                    fraction: card.memUsed
                }
                Reading {
                    visible: (card.sys.memory?.swap_used_gib ?? 0) > 0
                    key: "SWAP"
                    value: panel.gib(card.sys.memory?.swap_used_gib ?? 0)
                }
                Reading {
                    visible: card.sys.nvme_temps_c !== undefined
                    key: "NVME"
                    value: panel.temp(panel.hottest(card.sys.nvme_temps_c))
                    tone: panel.heat(panel.hottest(card.sys.nvme_temps_c), 60, 70)
                }
            }

            Section {
                text: "DISKS"
                visible: card.disks.length > 0
            }
            Repeater {
                model: card.disks

                // Mount, a gauge across the card, used / total.
                RowLayout {
                    id: disk

                    required property var modelData
                    readonly property var d: modelData[1]
                    readonly property real used: d.used_percent / 100

                    Layout.fillWidth: true
                    spacing: 8

                    Label {
                        Layout.preferredWidth: 56
                        text: disk.modelData[0].toUpperCase()
                        color: Theme.dim
                        font.pixelSize: 10
                        font.letterSpacing: 1
                        elide: Text.ElideMiddle
                    }
                    Item {
                        Layout.fillWidth: true
                        implicitHeight: diskGauge.implicitHeight

                        Gauge {
                            id: diskGauge
                            anchors.verticalCenter: parent.verticalCenter
                            segments: Math.max(10, Math.floor((parent.width + 2) / 5))
                            value: disk.used
                            color: panel.fill(disk.used)
                        }
                    }
                    Label {
                        text: panel.gib(disk.d.total_gib - disk.d.free_gib) + " / " + panel.gib(disk.d.total_gib)
                        color: disk.used >= 0.95 ? Theme.urgent : disk.used >= 0.85 ? Theme.warn : Theme.fg
                        font.pixelSize: 11
                    }
                }
            }

            Section {
                text: "GPUS"
                visible: (card.r?.gpus ?? []).length > 0
            }
            Repeater {
                model: card.r?.gpus ?? []

                // Card and role on the left, its readings on the right.
                RowLayout {
                    id: gpu

                    required property var modelData
                    readonly property real used: modelData.vram_total_mib ? 1 - modelData.vram_free_mib / modelData.vram_total_mib : -1
                    readonly property real hot: panel.hottest(modelData.temps_c)

                    Layout.fillWidth: true
                    spacing: 8

                    Label {
                        Layout.preferredWidth: 56
                        text: gpu.modelData.short.toUpperCase()
                        font.pixelSize: 11
                        font.bold: true
                        elide: Text.ElideRight
                    }
                    Label {
                        Layout.fillWidth: true
                        text: (gpu.modelData.role ?? "").toUpperCase()
                        color: Theme.muted
                        font.pixelSize: 9
                        font.letterSpacing: 1
                        elide: Text.ElideRight
                    }
                    Row {
                        spacing: 12

                        Reading {
                            key: "VRAM"
                            value: gpu.used >= 0 ? panel.pad(gpu.used * 100) + "%" : "--"
                            fraction: gpu.used
                        }
                        Reading {
                            key: "TEMP"
                            value: panel.temp(gpu.hot)
                            tone: panel.heat(gpu.hot, 80, 95)
                        }
                        Reading {
                            visible: gpu.modelData.power_w !== undefined
                            key: "PWR"
                            value: Math.round(gpu.modelData.power_w ?? 0) + "/" + Math.round(gpu.modelData.power_cap_w ?? 0) + "W"
                        }
                    }
                }
            }

            Section {
                text: "MODELS · " + card.models.filter(m => m[1] === "ready").length + "/" + card.models.length + " READY"
                visible: card.models.length > 0 || card.missingModels.length > 0
            }
            Flow {
                visible: card.models.length > 0 || card.missingModels.length > 0
                Layout.fillWidth: true
                spacing: 4

                Repeater {
                    model: card.models

                    Chip {
                        required property var modelData
                        text: modelData[0].toUpperCase()
                        tone: modelData[1] === "ready" ? Theme.good : Theme.warn
                    }
                }
                Repeater {
                    model: card.missingModels

                    Chip {
                        required property var modelData
                        text: String(modelData).toUpperCase() + " MISSING"
                        tone: Theme.urgent
                    }
                }
            }

            Section {
                text: "SERVICES · " + card.services.filter(s => s[1].state === "active/running").length + "/" + card.services.length + " RUNNING"
                visible: card.services.length > 0
            }
            Flow {
                visible: card.services.length > 0
                Layout.fillWidth: true
                spacing: 4

                Repeater {
                    model: card.services

                    // Restarts and errors in the last day count up beside the name.
                    Chip {
                        required property var modelData
                        readonly property var s: modelData[1]
                        readonly property bool running: s.state === "active/running"
                        readonly property bool failed: s.state.startsWith("failed")
                        readonly property int trouble: (s.restarts ?? 0) + (s.errors_24h ?? 0)

                        text: modelData[0].toUpperCase() + (trouble > 0 ? " ▲" + trouble : "")
                        tone: failed ? Theme.urgent : !running || trouble > 0 ? Theme.warn : Theme.good
                    }
                }
            }
            Repeater {
                model: card.failedUnits

                Label {
                    required property var modelData
                    Layout.fillWidth: true
                    text: "✕ " + (modelData.unit ?? modelData) + " FAILED"
                    color: Theme.urgent
                    font.pixelSize: 10
                    elide: Text.ElideRight
                }
            }

            // Hardware health and config drift on one line, amber or red when something's off;
            // drift's specifics follow underneath.
            Section {
                text: "HEALTH"
                visible: card.nvme.length > 0 || card.hw.btrfs_errors !== undefined || card.hasDrift
            }
            Flow {
                visible: card.nvme.length > 0 || card.hw.btrfs_errors !== undefined || card.hasDrift
                Layout.fillWidth: true
                spacing: 14

                Repeater {
                    model: card.nvme

                    Reading {
                        required property var modelData
                        readonly property var n: modelData[1]
                        readonly property bool bad: n.critical_warning > 0 || n.media_errors > 0 || n.available_spare_percent <= n.spare_threshold_percent

                        key: modelData[0].toUpperCase()
                        value: n.critical_warning > 0 ? "CRITICAL" : n.media_errors > 0 ? n.media_errors + " MEDIA ERR"
                            : n.percent_used + "% WORN"
                        tone: bad ? Theme.urgent : n.percent_used >= 80 ? Theme.warn : Theme.fg
                    }
                }
                Reading {
                    visible: card.hw.btrfs_errors !== undefined
                    key: "BTRFS"
                    value: card.btrfsErrors === 0 ? "CLEAN" : card.btrfsErrors + " ERR"
                    tone: card.btrfsErrors === 0 ? Theme.fg : Theme.urgent
                }
                Reading {
                    visible: card.kernelIssues > 0
                    key: "KERNEL"
                    value: card.kernelIssues + " ISSUES"
                    tone: Theme.warn
                }
                Reading {
                    visible: card.hasDrift
                    key: "DRIFT"
                    value: card.drift.length === 0 ? "NONE" : String(card.drift.length)
                    tone: card.drift.length === 0 ? Theme.fg : Theme.warn
                }
            }
            Repeater {
                model: card.drift

                Label {
                    required property string modelData
                    Layout.fillWidth: true
                    text: "◇ " + modelData
                    color: Theme.warn
                    font.pixelSize: 10
                    elide: Text.ElideRight
                }
            }

            // What needs looking at, as the monitor words it.
            Section {
                text: "WARNINGS · " + String(card.warnings.length).padStart(2, "0")
                visible: card.warnings.length > 0
                color: Theme.warn
            }
            Repeater {
                model: card.warnings

                Label {
                    required property string modelData
                    Layout.fillWidth: true
                    text: "▲ " + modelData
                    color: Theme.warn
                    font.pixelSize: 10
                    wrapMode: Text.Wrap
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
            color: panel.fill(parent.fraction)
        }
        Label {
            anchors.verticalCenter: parent.verticalCenter
            text: parent.value
            color: parent.tone
            font.pixelSize: 11
        }
    }

    // A boxed name in its state's colour: a model or a service.
    component Chip: Rectangle {
        property alias text: chipLabel.text
        property color tone: Theme.good

        implicitWidth: chipLabel.implicitWidth + 10
        implicitHeight: 16
        color: Qt.rgba(tone.r, tone.g, tone.b, 0.12)
        border.width: 1
        border.color: Qt.rgba(tone.r, tone.g, tone.b, 0.6)

        Label {
            id: chipLabel
            anchors.centerIn: parent
            color: parent.tone
            font.pixelSize: 9
            font.bold: true
            font.letterSpacing: 1
        }
    }

    component PageButton: Rectangle {
        id: button

        property alias text: label.text
        signal clicked

        implicitWidth: label.implicitWidth + 16
        implicitHeight: 20
        opacity: enabled ? 1 : 0.4
        color: press.containsMouse ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.2) : "transparent"
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
            enabled: button.enabled
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: button.clicked()
        }
    }
}
