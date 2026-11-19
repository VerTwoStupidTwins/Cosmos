// The keyboard backlight, on machines that have one (a "*::kbd_backlight" LED). It keeps the level
// the owner picked with Alt + the brightness keys (`qs -c bar ipc call kbdlight up|down`) and
// shows it while the keyboard can be used; after a minute idle, or while the laptop is folded into
// a tablet (the keyboard is off then), it goes dark and comes back at that level. Remembered across
// bar restarts and logins. Made once in shell.qml, so it starts with the bar.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

Scope {
    id: root

    readonly property string device: "*::kbd_backlight"
    readonly property int step: 10
    // Found by the first brightnessctl read.
    property bool available: false
    // The owner's level, 0–100.
    property int level: 50
    // Whether that level came from the store; otherwise it's taken from the light itself.
    property bool remembered: false
    readonly property bool dark: idle.isIdle || Tablet.active

    function adjust(delta) {
        if (!available) return;
        level = Math.max(0, Math.min(100, level + delta));
        store.setText(String(level));
        apply();
        OsdBus.keyboardLight(level / 100);
    }

    function apply() {
        if (!available) return;
        Quickshell.execDetached([Config.brightnessctl, "--quiet", "--device=" + device, "set", (dark ? 0 : level) + "%"]);
    }

    onDarkChanged: apply()

    // `qs -c bar ipc call kbdlight up|down`, which Alt + the brightness keys run.
    IpcHandler {
        target: "kbdlight"

        function up(): void {
            root.adjust(root.step);
        }
        function down(): void {
            root.adjust(-root.step);
        }
    }

    // Caffeine's inhibitor keeps it lit too.
    IdleMonitor {
        id: idle
        enabled: root.available
        timeout: 60
        respectInhibitors: true
    }

    // Prints e.g. "chromeos::kbd_backlight,leds,50,50%,100"; fails where there is no such light.
    Process {
        running: true
        command: [Config.brightnessctl, "--machine-readable", "--device=" + root.device]
        stdout: StdioCollector {
            onStreamFinished: {
                const fields = text.trim().split(",");
                if (fields.length < 4 || fields[1] !== "leds") return;
                root.available = true;
                if (!root.remembered) root.level = parseInt(fields[3]);
                root.apply();
            }
        }
    }

    FileView {
        id: store
        path: Quickshell.statePath("kbdlight")
        printErrors: false
        onLoaded: {
            const n = parseInt(text());
            if (isNaN(n)) return;
            root.level = Math.max(0, Math.min(100, n));
            root.remembered = true;
            root.apply();
        }
    }
}
