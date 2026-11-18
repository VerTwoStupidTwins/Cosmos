// While a recording's region is being picked: a plate in the middle of the screen saying so, since
// slurp itself only darkens the screen. Clicks pass through to slurp.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

PanelWindow {
    // Shown a moment after slurp's overlay, so niri stacks it above rather than under the dimming.
    visible: Recorder.picking && delay.done

    Timer {
        id: delay
        property bool done: false
        interval: 350
        running: Recorder.picking
        onRunningChanged: if (running) done = false
        onTriggered: done = true
    }

    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-recorder-hint"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    color: "transparent"
    mask: Region {}

    implicitWidth: plate.implicitWidth
    implicitHeight: plate.implicitHeight

    Plate {
        id: plate
        title: "REC"
        status: "SELECT REGION"
        statusTone: Theme.urgent
        cutTopLeft: 10
        cutBottomRight: 10
        padding: 16

        Label {
            Layout.alignment: Qt.AlignHCenter
            text: "DRAG A REGION TO RECORD"
            color: Theme.fg
            font.pixelSize: 15
            font.bold: true
            font.letterSpacing: 3
        }
        Label {
            Layout.alignment: Qt.AlignHCenter
            text: "ESC CANCELS"
            color: Theme.dim
            font.pixelSize: 10
            font.letterSpacing: 2
        }
    }
}
