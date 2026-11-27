// Which of the bottom bar's plates is open: "media", "network", "audio", "bluetooth", "drives" or none. One at a time,
// since they all rise from the same edge.
pragma Singleton

import Quickshell

Singleton {
    property string open: ""
    // The clipboard history, a full-screen picker rather than a bottom plate.
    property bool clipboard: false
    // How long a page or plate stays open without the pointer over it (LabPanel, StationPanel, and the
    // VOL, COM and BT plates).
    readonly property int idleClose: 4000

    function toggle(name) {
        open = open === name ? "" : name;
    }
}
