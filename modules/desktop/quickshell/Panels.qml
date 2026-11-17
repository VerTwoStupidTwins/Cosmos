// Which of the bottom bar's plates is open: "media", "network", "audio" or none. One at a time,
// since they all rise from the same edge.
pragma Singleton

import Quickshell

Singleton {
    property string open: ""

    function toggle(name) {
        open = open === name ? "" : name;
    }
}
