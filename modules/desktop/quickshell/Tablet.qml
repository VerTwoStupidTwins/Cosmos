// Tablet mode on 2-in-1s (Config.convertible): follows the tablet-mode switch with evtest, through
// the /dev/input/tablet-mode link the convertible module makes. While the laptop is folded back:
// - iio-niri turns the built-in screen to match the accelerometer, unless rotation is locked;
//   folding back to a laptop puts the screen upright again;
// - wvkbd runs as the input method, so its keyboard comes up whenever a text field has focus (and
//   KBD on the bar shows or hides it by hand).
// - the bars' plates grow to finger size (barScale), and EdgeSwipes puts touch strips on the edges.
// libinput turns the keyboard and touchpad off by itself in tablet mode.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property bool available: Config.convertible
    property bool active: false
    property bool rotationLocked: false
    // The bars grow for fingers while folded; panels that hang off a bar sit below barHeight.
    readonly property real barScale: active ? 1.3 : 1
    readonly property int barHeight: Math.round(40 * barScale)
    // The built-in screen, the one with the accelerometer.
    readonly property string output: "eDP-1"
    readonly property string device: "/dev/input/tablet-mode"

    function toggleRotationLock() {
        rotationLocked = !rotationLocked;
    }
    // wvkbd toggles on SIGRTMIN, which is 34 with glibc.
    function toggleKeyboard() {
        if (keyboard.running) keyboard.signal(34);
    }
    // For trying tablet mode without folding the laptop; the next real fold or unfold wins.
    function toggle() {
        if (available) active = !active;
    }

    onActiveChanged: {
        if (active) return;
        rotationLocked = false;
        Quickshell.execDetached(["niri", "msg", "output", output, "transform", "normal"]);
    }

    function hex(c) {
        return c.toString().slice(1);
    }

    // Where the switch is now, at start and whenever the watcher (re)connects…
    Process {
        id: query
        running: root.available
        command: [Config.evtest, "--query", root.device, "EV_SW", "SW_TABLET_MODE"]
        // evtest --query exits 10 when the switch is on, 0 when it's off.
        onExited: code => root.active = code === 10
    }

    // …and every time it flips.
    Process {
        id: watcher
        running: root.available
        command: [Config.evtest, root.device]
        stdout: SplitParser {
            onRead: line => {
                const m = line.match(/\(SW_TABLET_MODE\), value (\d)/);
                if (m) root.active = m[1] === "1";
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

    Process {
        id: rotator
        running: root.active && !root.rotationLocked
        command: [Config.iioNiri, "listen", "--monitor", root.output]
    }

    Process {
        id: keyboard
        running: root.active
        // It takes room from the bottom of the screen while shown, so the field being typed in stays
        // in view.
        command: [Config.wvkbd, "--auto", "--hidden",
            "--fn", Theme.font + " 16",
            "--bg", root.hex(Theme.bg), "--fg", root.hex(Theme.surface), "--fg-sp", root.hex(Theme.bg),
            "--press", root.hex(Theme.accent), "--press-sp", root.hex(Theme.accent),
            "--swipe", root.hex(Theme.accent), "--swipe-sp", root.hex(Theme.accent),
            "--text", root.hex(Theme.fg), "--text-sp", root.hex(Theme.accent),
            "--text-press", root.hex(Theme.bg), "--text-press-sp", root.hex(Theme.bg)]
    }
    // A new wallpaper changes the colours; wvkbd only takes them at start.
    Connections {
        target: Theme
        function onAccentChanged() {
            if (!keyboard.running) return;
            keyboard.running = false;
            restartKeyboard.start();
        }
    }
    Timer {
        id: restartKeyboard
        interval: 300
        onTriggered: keyboard.running = root.active
    }
}
