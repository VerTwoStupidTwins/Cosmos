// Removable drives on the bottom bar: the drive's name (or how many), lit while one is mounted.
// A click opens the drives plate. Hidden while none are plugged in.
import QtQuick

Readout {
    visible: Drives.drives.length > 0
    tag: "DRV"
    showGauge: false
    reading: Drives.drives.length === 1 ? Drives.drives[0].name.toUpperCase().slice(0, 14) : Drives.drives.length + " DRV"
    tone: Drives.mounted > 0 ? Theme.accent : Theme.muted

    onPressed: Panels.toggle("drives")
}
