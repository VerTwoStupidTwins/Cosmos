// Lets the bar's own controls show the OSD: brightness has no change signal to watch (Osd.qml).
pragma Singleton

import Quickshell

Singleton {
    signal brightness
}
