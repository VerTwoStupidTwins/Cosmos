// Bluetooth on the bottom bar: the connected device (or how many), ON or OFF. A click opens the
// Bluetooth plate. Hidden without an adapter.
import QtQuick
import Quickshell.Bluetooth

Readout {
    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property bool on: adapter?.enabled ?? false
    readonly property var connected: adapter ? Array.from(adapter.devices.values).filter(d => d.connected) : []

    visible: adapter !== null
    tag: "BT"
    showGauge: false
    reading: !on ? "OFF" : connected.length === 1 ? connected[0].name.slice(0, 14) : connected.length > 1 ? connected.length + " DEV" : "ON"
    tone: on ? Theme.accent : Theme.muted

    onPressed: Panels.toggle("bluetooth")
}
