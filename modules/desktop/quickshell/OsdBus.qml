// Lets the bar's own controls show the OSD: brightness has no change signal to watch (Osd.qml), and
// the keyboard backlight's level (0–1) comes from KbdLight.
pragma Singleton

import Quickshell

Singleton {
    signal brightness
    signal keyboardLight(real level)
}
