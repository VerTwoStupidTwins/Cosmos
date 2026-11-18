// The homelab's health, for the command station's LAB plate: Config.homelab asks each lab host's
// monitor (host-monitor, over SSH with the bar's own key) for its health report. It checks when
// the station opens, if the last check is over half a minute old, and every minute while it's
// open; never while it's closed.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property bool available: Config.homelab !== ""
    // One entry per host: { host, report } or { host, error }.
    property var hosts: []
    property date checkedAt: new Date(0)
    readonly property bool checking: probe.running

    function check() {
        if (available && !probe.running) probe.running = true;
    }

    Connections {
        target: Station
        function onOpenChanged() {
            if (Station.open && Date.now() - root.checkedAt.getTime() > 30000) root.check();
        }
    }

    Timer {
        interval: 60000
        repeat: true
        running: Station.open && root.available
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
