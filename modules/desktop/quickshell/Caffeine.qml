// Caffeine: while on, the bar holds an idle inhibitor, so the screen doesn't dim, lock or turn off
// (hypridle only acts when niri reports the session idle, which an inhibitor prevents). It starts
// off with every login and bar restart.
pragma Singleton

import Quickshell

Singleton {
    property bool on: false

    function toggle() {
        on = !on;
    }
}
