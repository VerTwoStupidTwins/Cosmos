// The stylus on 2-in-1s with a pen garage (Config.convertible): follows the garage switch with
// evtest, through the /dev/input/pen-garage link the convertible module makes. Pulling the pen out
// brings up the pen menu (PenMenu.qml); putting it back closes it. The pen's battery comes from
// its HID power supply, which only reports while the pen has touched the screen recently.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property bool available: Config.convertible && Config.rnote !== ""
    property bool out: false
    property bool menu: false
    // 0–100, or -1 while the pen isn't reporting.
    property int battery: -1
    readonly property string device: "/dev/input/pen-garage"
    // Screenshots and mark-ups land with niri's own screenshots.
    readonly property string pictures: Quickshell.env("HOME") + "/Pictures/Screenshots"

    function toggleMenu() {
        menu = !menu;
    }

    function launch(command) {
        menu = false;
        Quickshell.execDetached([Config.systemdRun, "--user", "--scope", "--collect", "--quiet", "--slice=app.slice", "--"].concat(command));
    }
    function note() {
        launch([Config.rnote]);
    }
    function paint() {
        launch(["krita"]);
    }
    // Grab a region (or the whole screen) and open it in satty to draw on; satty saves beside the
    // screenshots and copies on request.
    function markUp(region) {
        menu = false;
        const grab = region ? '"$GRIM" -g "$("$SLURP" < /dev/null)" -' : '"$GRIM" -o "$OUTPUT" -';
        Quickshell.execDetached({
            command: [Config.bash, "-c", 'mkdir -p "$DIR" && ' + grab + ' | "$SATTY" --filename - --output-filename "$DIR/markup-%Y-%m-%d_%H-%M-%S.png" --copy-command "$WLCOPY"' + (region ? '' : ' --fullscreen')],
            environment: {
                GRIM: Config.grim, SLURP: Config.slurp, SATTY: Config.satty, WLCOPY: Config.wlCopy,
                DIR: root.pictures, OUTPUT: Tablet.output
            }
        });
    }

    onOutChanged: {
        menu = out;
        if (out) batteryReader.running = true;
    }

    // Where the pen is at start, and whenever the watcher (re)connects…
    Process {
        id: query
        running: root.available
        command: [Config.evtest, "--query", root.device, "EV_SW", "SW_PEN_INSERTED"]
        // evtest --query exits 10 when the switch is on: the pen is in its garage.
        onExited: code => root.out = code === 0
    }

    // …and every time it goes in or out.
    Process {
        id: watcher
        running: root.available
        command: [Config.evtest, root.device]
        stdout: SplitParser {
            onRead: line => {
                const m = line.match(/\(SW_PEN_INSERTED\), value (\d)/);
                if (m) root.out = m[1] === "0";
            }
        }
        onExited: retry.start()
    }
    Timer {
        id: retry
        interval: 5000
        onTriggered: {
            query.running = root.available;
            watcher.running = root.available;
        }
    }

    // The pen's charge: the HID battery whose scope is Device and whose model is the digitiser.
    Process {
        id: batteryReader
        command: [Config.bash, "-c", 'for b in /sys/class/power_supply/*; do [ "$(cat "$b/scope" 2>/dev/null)" = Device ] && [ "$(cat "$b/status" 2>/dev/null)" != Unknown ] && cat "$b/capacity" && exit; done; echo -1']
        stdout: StdioCollector {
            onStreamFinished: {
                const n = parseInt(text.trim());
                root.battery = isNaN(n) ? -1 : n;
            }
        }
    }
    Timer {
        interval: 60000
        repeat: true
        running: root.out
        onTriggered: batteryReader.running = true
    }
}
