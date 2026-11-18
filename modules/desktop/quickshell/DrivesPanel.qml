// The drives plate: rises over the bottom bar's right plate when DRV is clicked. Each removable
// drive with EJECT (unmount everything, then power it off), and its volumes below it with how full
// they are. A click on a mounted volume opens it in the file manager, on an unmounted one mounts
// it; the volume's button unmounts or mounts. Locked LUKS volumes are left to udiskie's prompt.
// Esc closes.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: panel

    visible: Panels.open === "drives"
    anchors.bottom: true
    anchors.right: true
    margins.bottom: 42
    margins.right: 8
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-drives"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    color: "transparent"

    implicitWidth: 400
    implicitHeight: plate.implicitHeight + 4

    onVisibleChanged: if (visible) {
        keys.forceActiveFocus();
        Drives.refresh();
    }

    // Pulling the last drive leaves nothing to show.
    Connections {
        target: Drives
        function onDrivesChanged() {
            if (Drives.drives.length === 0 && Panels.open === "drives") Panels.open = "";
        }
    }

    Item {
        id: keys
        focus: true
        Keys.onEscapePressed: Panels.open = ""
    }

    Plate {
        id: plate
        width: parent.width
        anchors.bottom: parent.bottom
        title: "DRV"
        status: Drives.busy !== "" ? "WORKING" : String(Drives.mounted).padStart(2, "0") + " MOUNTED"
        statusTone: Drives.busy !== "" ? Theme.warn : Drives.mounted > 0 ? Theme.good : Theme.muted
        cutTopLeft: 14
        cutBottomRight: 4
        cutBottomLeft: 10
        stripRight: true
        padding: 14

        Repeater {
            model: Drives.drives

            ColumnLayout {
                id: drive

                required property var modelData
                required property int index

                Layout.fillWidth: true
                Layout.topMargin: index > 0 ? 8 : 0
                spacing: 4

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Text {
                        text: "󰕓"
                        color: Theme.accent
                        font.family: Theme.font
                        font.pixelSize: 14
                    }
                    Label {
                        Layout.fillWidth: true
                        text: drive.modelData.name.toUpperCase()
                        font.pixelSize: 11
                        font.bold: true
                        font.letterSpacing: 1
                        elide: Text.ElideRight
                    }
                    Label {
                        text: Drives.size(drive.modelData.size)
                        color: Theme.dim
                        font.pixelSize: 10
                    }
                    PanelButton {
                        text: Drives.busy === drive.modelData.path ? "EJECTING" : "EJECT"
                        lit: Drives.busy === drive.modelData.path
                        enabled: Drives.busy === ""
                        onClicked: Drives.eject(drive.modelData)
                    }
                }

                Label {
                    visible: drive.modelData.volumes.length === 0
                    text: "NO FILESYSTEM"
                    color: Theme.muted
                    font.pixelSize: 9
                    font.letterSpacing: 2
                }

                Repeater {
                    model: drive.modelData.volumes

                    VolumeRow {
                        required property var modelData
                        volume: modelData
                    }
                }
            }
        }
    }

    component VolumeRow: Item {
        id: row

        required property var volume
        readonly property bool mounted: volume.mountpoint !== ""
        readonly property bool busy: Drives.busy === volume.path
        readonly property real fill: volume.size > 0 ? volume.used / volume.size : 0

        Layout.fillWidth: true
        implicitHeight: 40

        HoverHandler {
            id: hover
        }
        PlateShape {
            anchors.fill: parent
            cutTopLeft: 6
            cutBottomRight: 6
            fillOpacity: row.mounted ? 0.8 : hover.hovered ? 0.6 : 0.3
            showStrip: false
            frameColor: row.mounted ? Theme.accent : Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, hover.hovered ? 0.5 : 0.2)
        }
        MouseArea {
            anchors.fill: parent
            enabled: !row.volume.locked && Drives.busy === ""
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (row.mounted) {
                    Drives.open(row.volume);
                    Panels.open = "";
                } else {
                    Drives.mount(row.volume);
                }
            }
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 8
            spacing: 8

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1

                Label {
                    Layout.fillWidth: true
                    text: row.volume.label
                    color: row.mounted ? Theme.fg : Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.85)
                    font.pixelSize: 12
                    font.bold: row.mounted
                    elide: Text.ElideRight
                }
                Label {
                    Layout.fillWidth: true
                    text: row.volume.locked ? "ENCRYPTED · LOCKED"
                        : (row.volume.fstype.toUpperCase() + (row.mounted ? " · " + row.volume.mountpoint : ""))
                    color: Theme.muted
                    font.pixelSize: 9
                    elide: Text.ElideMiddle
                }
            }
            // How full it is, once mounted (the kernel only knows then).
            Gauge {
                visible: row.mounted
                Layout.alignment: Qt.AlignVCenter
                segments: 8
                value: row.fill
                color: row.fill >= 0.9 ? Theme.urgent : row.fill >= 0.75 ? Theme.warn : Theme.accent
            }
            Label {
                text: row.mounted ? Drives.size(row.volume.size - row.volume.used) + " FREE" : Drives.size(row.volume.size)
                color: Theme.dim
                font.pixelSize: 10
            }
            PanelButton {
                visible: !row.volume.locked
                text: row.busy ? (row.mounted ? "UNMOUNTING" : "MOUNTING") : row.mounted ? "UNMOUNT" : "MOUNT"
                lit: row.busy
                enabled: Drives.busy === ""
                onClicked: row.mounted ? Drives.unmount(row.volume) : Drives.mount(row.volume)
            }
        }
    }

    component PanelButton: Rectangle {
        id: button

        property alias text: label.text
        property bool lit: false
        signal clicked

        implicitWidth: label.implicitWidth + 16
        implicitHeight: 20
        opacity: enabled || lit ? 1 : 0.4
        color: lit || press.containsMouse ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.2) : "transparent"
        border.width: 1
        border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.7)

        Label {
            id: label
            anchors.centerIn: parent
            color: Theme.accent
            font.pixelSize: 10
            font.bold: true
            font.letterSpacing: 1
        }
        MouseArea {
            id: press
            anchors.fill: parent
            enabled: button.enabled
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: button.clicked()
        }
    }
}
