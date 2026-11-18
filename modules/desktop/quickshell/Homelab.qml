// The homelab's health, for the LAB page (LabPanel.qml): Config.homelab asks each lab host's
// monitor (host-monitor, over SSH with the bar's own key) for its health report. It checks when
// the page opens, if the last check is over half a minute old, and every minute while it's open;
// never while it's closed. The page and the command station drop down from the same place, so
// opening one closes the other.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property bool available: Config.homelab !== ""
    property bool open: false
    // One entry per host: { host, report } or { host, error }.
    property var hosts: []
    property date checkedAt: new Date(0)
    readonly property bool checking: probe.running
    readonly property int healthy: hosts.filter(h => h.report?.status === "ok").length

    function toggle() {
        if (open) open = false;
        else show();
    }
    function show() {
        if (!available) return;
        Station.open = false;
        open = true;
    }
    function check() {
        if (available && !probe.running) probe.running = true;
    }

    onOpenChanged: if (open && Date.now() - checkedAt.getTime() > 30000) check()

    Connections {
        target: Station
        function onOpenChanged() {
            if (Station.open) root.open = false;
        }
    }

    Timer {
        interval: 60000
        repeat: true
        running: root.open && root.available
        onTriggered: root.check()
    }

    Process {
        id: probe
        command: [Config.homelab]
        stdout: StdioCollector {
            onStreamFinished: {
                const hosts = [];
                for (const line of text.split("\n")) {
                    try {
                        if (line.trim() !== "") hosts.push(JSON.parse(line));
                    } catch (e) {}
                }
                root.hosts = hosts.sort((a, b) => a.host.localeCompare(b.host));
                root.checkedAt = new Date();
            }
        }
    }
}
