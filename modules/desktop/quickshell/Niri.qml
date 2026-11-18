// niri's event stream, followed for what ext-workspace doesn't say: which windows are on which
// workspace (for the workspace icons) and when a screenshot is taken (Screenshots.qml). Empty
// under other compositors.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property bool available: Quickshell.env("NIRI_SOCKET") !== ""
    property var workspaces: []
    // Window id → window, as niri describes them (app_id, workspace_id, title…).
    property var windows: ({})

    signal screenshotCaptured(string path)

    // The distinct app ids on the workspace ext-workspace calls `name`, in window order.
    function appsOn(name) {
        const ws = workspaces.find(w => String(w.name ?? w.idx) === String(name));
        if (!ws) return [];
        const ids = Object.values(windows).filter(w => w.workspace_id === ws.id).map(w => w.app_id || "");
        return Array.from(new Set(ids.filter(id => id !== "")));
    }

    function handle(event) {
        if (event.WorkspacesChanged) {
            workspaces = event.WorkspacesChanged.workspaces;
        } else if (event.WindowsChanged) {
            const map = {};
            for (const w of event.WindowsChanged.windows) map[w.id] = w;
            windows = map;
        } else if (event.WindowOpenedOrChanged) {
            const w = event.WindowOpenedOrChanged.window;
            windows = Object.assign({}, windows, { [w.id]: w });
        } else if (event.WindowClosed) {
            const next = Object.assign({}, windows);
            delete next[event.WindowClosed.id];
            windows = next;
        } else if (event.ScreenshotCaptured?.path) {
            screenshotCaptured(event.ScreenshotCaptured.path);
        }
    }

    // Restarted if the stream ends, as when niri reloads.
    Process {
        id: events
        running: root.available
        command: ["niri", "msg", "--json", "event-stream"]
        stdout: SplitParser {
            onRead: line => {
                try {
                    root.handle(JSON.parse(line));
                } catch (e) {}
            }
        }
        onExited: restart.start()
    }
    Timer {
        id: restart
        interval: 2000
        onTriggered: events.running = true
    }
}
