// The link NetworkManager has up: wired, or Wi-Fi with its signal as a four-bar meter.
import QtQuick
import Quickshell.Networking

Readout {
    id: root

    readonly property var devices: Array.from(Networking.devices.values)
    readonly property var wired: devices.find(d => d.type === DeviceType.Wired && d.connected) ?? null
    readonly property var wifi: devices.find(d => d.type === DeviceType.Wifi && d.connected) ?? null
    readonly property var network: wifi ? Array.from(wifi.networks.values).find(n => n.connected) ?? null : null

    tag: "COM"
    segments: 4
    value: wired ? 1 : network ? network.signalStrength : 0
    reading: wired ? "WIRED" : network ? network.name : "NO LINK"
    tone: wired || network ? Theme.accent : Theme.urgent
}
