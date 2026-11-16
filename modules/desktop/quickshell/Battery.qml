// The laptop battery from UPower; hidden on machines without one.
import QtQuick
import Quickshell.Services.UPower

Readout {
    id: root

    readonly property var device: UPower.displayDevice
    readonly property bool present: device?.ready && device.isPresent && device.type === UPowerDeviceType.Battery
    // Quickshell reports 0–1; allow for 0–100 too.
    readonly property int percent: present
        ? Math.round(device.percentage <= 1 ? device.percentage * 100 : device.percentage) : 0
    readonly property bool charging: present
        && (device.state === UPowerDeviceState.Charging || device.state === UPowerDeviceState.FullyCharged)

    visible: present
    tag: "PWR"
    value: percent / 100
    reading: String(percent).padStart(3, "0") + (charging ? "+" : "")
    tone: charging ? Theme.good : percent <= 10 ? Theme.urgent : percent <= 25 ? Theme.warn : Theme.accent
}
