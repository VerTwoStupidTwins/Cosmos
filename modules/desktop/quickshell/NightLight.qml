// Night light: while on, gammastep holds the screen at a warm 4500 K. Remembered across bar
// restarts and logins.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property bool on: false
    readonly property int temperature: 4500

    function toggle() {
        on = !on;
        store.setText(on ? "on" : "off");
    }

    Process {
        running: root.on
        command: [Config.gammastep, "-m", "wayland", "-O", String(root.temperature)]
    }

    FileView {
        id: store
        path: Quickshell.statePath("nightlight")
        printErrors: false
        onLoaded: root.on = text().trim() === "on"
    }
}
