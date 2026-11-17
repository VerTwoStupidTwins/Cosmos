// One screen's lock surface, showing the lock screen.
import QtQuick
import Quickshell.Wayland

WlSessionLockSurface {
    id: surface

    required property var lock

    color: "black"

    LockScreen {
        anchors.fill: parent
        lock: surface.lock
    }
}
