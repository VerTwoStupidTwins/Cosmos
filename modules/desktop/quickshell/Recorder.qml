// Screen recording with wf-recorder: a region picked with slurp, or the whole screen, with the
// desktop's sound, encoded on the GPU (VAAPI H.264) to ~/Videos/Recordings. The bar shows REC and
// the time while it runs; clicking that, or the same key again, stops it, and a notification with
// the path and a thumbnail of the first frame follows (click to open the video).
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property bool busy: recorder.running
    property bool recording: false
    // While slurp waits for a region (RecorderHint.qml says so on screen).
    property bool picking: false
    property real started: 0
    property int elapsed: 0
    property string file: ""

    readonly property string dir: Quickshell.env("HOME") + "/Videos/Recordings"

    function hex(c, alpha) {
        const h = v => Math.round(v * 255).toString(16).padStart(2, "0");
        return "#" + h(c.r) + h(c.g) + h(c.b) + alpha;
    }

    // Starts a recording ("region" or "screen"), or stops the one running.
    function toggle(mode) {
        if (recorder.running) {
            stop();
            return;
        }
        file = dir + "/Recording from " + Qt.formatDateTime(new Date(), "yyyy-MM-dd HH-mm-ss") + ".mp4";
        const slurp = [Config.slurp, "-c", hex(Theme.accent, "ff"), "-b", "#000000aa", "-s", "#00000000", "-w", "2"]
            .map(a => "'" + a + "'").join(" ");
        // slurp reads predefined boxes from stdin when it isn't a terminal, and the bar's stdin is
        // a pipe that never closes, so it gets /dev/null.
        const geometry = mode === "region" ? 'g=$(' + slurp + ' < /dev/null) || exit 1; set -- -g "$g"' : "set --";
        recorder.command = [Config.bash, "-c", geometry + '; mkdir -p "$DIR" && echo START && exec "$WF" "$@" -c h264_vaapi -d /dev/dri/renderD128 --audio=@DEFAULT_MONITOR@ -f "$FILE"'];
        recorder.environment = { DIR: dir, FILE: file, WF: Config.wfRecorder };
        picking = mode === "region";
        recorder.running = true;
    }

    function stop() {
        if (recorder.running) recorder.signal(2); // SIGINT: wf-recorder finishes the file.
    }

    function shown(path) {
        const home = Quickshell.env("HOME");
        return path.startsWith(home + "/") ? "~" + path.slice(home.length) : path;
    }

    Process {
        id: recorder
        stdout: SplitParser {
            onRead: line => {
                if (line !== "START") return;
                root.picking = false;
                Quickshell.execDetached([Config.notifySend, "--app-name=Recorder", "--urgency=low", "--expire-time=2500",
                    "Recording", "Same key again, or click REC in the bar, to stop."]);
                root.started = Date.now();
                root.elapsed = 0;
                root.recording = true;
            }
        }
        onExited: {
            root.picking = false;
            if (root.recording) notifier.createObject(root, { path: root.file });
            root.recording = false;
        }
    }

    Timer {
        running: root.recording
        interval: 1000
        repeat: true
        onTriggered: root.elapsed = Math.floor((Date.now() - root.started) / 1000)
    }

    Component {
        id: notifier

        Process {
            id: notify

            required property string path

            readonly property string thumb: Quickshell.cachePath("recordings/" + path.split("/").pop() + ".png")

            // ffmpeg grabs the first frame for the thumbnail; notify-send then waits on the card.
            running: true
            environment: ({ FFMPEG: Config.ffmpeg, NOTIFY: Config.notifySend, VIDEO: path, THUMB: thumb, SHOWN: root.shown(path) })
            command: [Config.bash, "-c", 'mkdir -p "${THUMB%/*}"; "$FFMPEG" -loglevel error -y -i "$VIDEO" -frames:v 1 -vf scale=640:-2 "$THUMB" < /dev/null; '
                + 'exec "$NOTIFY" --app-name=Recorder --expire-time=7000 --hint=string:image-path:"file://$THUMB" '
                + '--hint=boolean:x-cosmos-preview:true --action=default=Open "Recording saved · click to open" "$SHOWN"']
            stdout: StdioCollector {
                onStreamFinished: if (text.trim() === "default")
                    Quickshell.execDetached([Config.systemdRun, "--user", "--scope", "--collect", "--quiet", "--slice=app.slice", "--", Config.xdgOpen, notify.path])
            }
            onExited: destroy()
        }
    }
}
