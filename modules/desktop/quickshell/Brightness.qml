// The backlight, read with brightnessctl every two seconds; hidden when there is none.
// Scroll to change it.
import QtQuick
import Quickshell
import Quickshell.Io

Readout {
    id: root

    property int percent: -1

    visible: percent >= 0
    tag: "BRT"
    value: percent / 100
    reading: String(percent).padStart(3, "0")

    // Prints e.g. "amdgpu_bl1,backlight,48,19%,255".
    Process {
        id: read
        command: [Config.brightnessctl, "--machine-readable", "--class=backlight"]
        stdout: StdioCollector {
            onStreamFinished: {
                const fields = text.trim().split(",");
                if (fields.length >= 4) root.percent = parseInt(fields[3]);
            }
        }
    }

    Timer {
        id: poll
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: read.running = true
    }

    Process {
        id: set
        onExited: {
            poll.restart();
            OsdBus.brightness();
        }
    }

    onScrolled: delta => {
        if (set.running) return;
        set.command = [Config.brightnessctl, "--class=backlight", "--quiet", "set", delta > 0 ? "5%+" : "5%-"];
        set.running = true;
    }
}
