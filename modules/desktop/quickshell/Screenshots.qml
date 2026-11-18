// Screenshots: niri takes them (its picker, saved to ~/Pictures/Screenshots and copied); for each
// one niri announces (Niri.qml), this posts a notification with a thumbnail and the path, for 7
// seconds. Clicking it opens the shot in satty to annotate, saving beside it as
// "<name>-annotated.png".
import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    function shown(path) {
        const home = Quickshell.env("HOME");
        return path.startsWith(home + "/") ? "~" + path.slice(home.length) : path;
    }

    function announce(path) {
        notifier.createObject(root, { path: path });
    }

    function annotate(path) {
        const out = path.replace(/(\.[^./]+)?$/, "-annotated.png");
        Quickshell.execDetached([Config.systemdRun, "--user", "--scope", "--collect", "--quiet", "--slice=app.slice", "--",
            Config.satty, "--filename", path, "--output-filename", out, "--copy-command", Config.wlCopy]);
    }

    Connections {
        target: Niri
        function onScreenshotCaptured(path) { root.announce(path); }
    }

    // notify-send waits while its card is up and prints "default" when it's clicked.
    Component {
        id: notifier

        Process {
            id: notify

            required property string path

            running: true
            command: [Config.notifySend, "--app-name=Screenshot", "--expire-time=7000",
                "--hint=string:image-path:file://" + path, "--hint=boolean:x-cosmos-preview:true",
                "--action=default=Annotate", "Screenshot saved · click to annotate", root.shown(path)]
            stdout: StdioCollector {
                onStreamFinished: if (text.trim() === "default") root.annotate(notify.path)
            }
            onExited: destroy()
        }
    }
}
