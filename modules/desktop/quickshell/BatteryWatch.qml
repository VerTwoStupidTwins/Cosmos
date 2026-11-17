// Warns about a low battery with a notification at 15%, and a critical one at 10% and 5%; each
// once per discharge, until the battery charges again.
import QtQuick
import Quickshell
import Quickshell.Services.UPower

Scope {
    id: root

    readonly property var device: UPower.displayDevice
    readonly property bool present: device?.ready && device.isPresent && device.type === UPowerDeviceType.Battery
    readonly property int percent: present
        ? Math.round(device.percentage <= 1 ? device.percentage * 100 : device.percentage) : 100
    readonly property bool discharging: present
        && (device.state === UPowerDeviceState.Discharging || device.state === UPowerDeviceState.PendingDischarge)
    // The lowest threshold warned about since it last charged.
    property int warned: 101

    readonly property var levels: [
        { at: 5, urgency: "critical", summary: "Battery at 5%", body: "Plug in now: the laptop will shut down soon." },
        { at: 10, urgency: "critical", summary: "Battery critically low", body: "10% left." },
        { at: 15, urgency: "normal", summary: "Battery low", body: "15% left." }
    ]

    function check() {
        if (!discharging) {
            warned = 101;
            return;
        }
        const level = levels.find(l => percent <= l.at);
        if (!level || level.at >= warned) return;
        warned = level.at;
        Quickshell.execDetached([Config.notifySend, "--app-name=Power", "--urgency=" + level.urgency,
            "--icon=battery-caution", level.summary, level.body]);
    }

    onPercentChanged: check()
    onDischargingChanged: check()
}
