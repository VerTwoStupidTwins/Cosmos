// Which of the bottom bar's plates is open: "media", "network", "audio", "bluetooth", "drives" or none. One at a time,
// since they all rise from the same edge.
pragma Singleton

import Quickshell

Singleton {
    property string open: ""
    // The clipboard history, a full-screen picker rather than a bottom plate.
    property bool clipboard: false

    function toggle(name) {
        open = open === name ? "" : name;
    }
}
