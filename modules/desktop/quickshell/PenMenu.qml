// The pen menu: a plate on the right edge that comes up when the stylus leaves its garage (Pen.qml),
// with big rows for the pen: a new Excalidraw drawing in the Notes vault, Krita, a region to mark up, or the whole
// screen to draw on. It goes away after a tap, after a few seconds with nothing moving over it, or when the pen goes back.
// The PEN readout on the bottom bar, or `qs -c bar ipc call pen menu`, brings it back.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: panel

    visible: Pen.menu
    anchors.right: true
    margins.right: 8
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-pen"
    // Never takes the keyboard: the pen is about to draw in whatever is focused.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    color: "transparent"

    implicitWidth: 300
    implicitHeight: plate.implicitHeight + 4

    // A few seconds (Panels.idleClose) with nothing moving over it, it gets out of the way. It counts from the last
    // movement, not from the pointer leaving: the menu comes up where the cursor or the hovering pen often already is,
    // and a pen that goes out of range over it never "leaves", which kept it open for good.
    Timer {
        id: idle
        interval: Panels.idleClose
        running: panel.visible
        onTriggered: Pen.menu = false
    }
    onVisibleChanged: if (visible) idle.restart()

    // Sees pen and mouse movement over the whole menu without taking presses from the rows.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        hoverEnabled: true
        onPositionChanged: idle.restart()
        onEntered: idle.restart()
    }

    Plate {
        id: plate
        width: parent.width
        anchors.verticalCenter: parent.verticalCenter
        title: "PEN"
        status: Pen.battery >= 0 ? String(Pen.battery).padStart(3, "0") + "%" : "BATT --"
        statusTone: Pen.battery < 0 ? Theme.muted : Pen.battery <= 15 ? Theme.urgent : Theme.dim
        cutTopLeft: 14
        cutBottomLeft: 4
        cutBottomRight: 0
        stripRight: true
        padding: 14

        Action {
            glyph: ""
            label: "NOTE"
            hint: "A new drawing in Notes"
            onPressed: Pen.note()
        }
        Action {
            glyph: ""
            label: "PAINT"
            hint: "Krita"
            onPressed: Pen.paint()
        }
        Action {
            glyph: "\u{f019e}"
            label: "SNIP"
            hint: "A region, to mark up"
            onPressed: Pen.markUp(true)
        }
        Action {
            glyph: "\u{f0e51}"
            label: "MARK UP SCREEN"
            hint: "The whole screen, to draw on"
            onPressed: Pen.markUp(false)
        }
    }

    // A row big enough to hit with a pen or a finger.
    component Action: Item {
        id: action

        property string glyph
        property string label
        property string hint
        signal pressed

        Layout.fillWidth: true
        implicitHeight: 48

        HoverHandler {
            id: rowHover
        }
        PlateShape {
            anchors.fill: parent
            cutTopLeft: 6
            cutBottomRight: 6
            showStrip: false
            fillOpacity: tap.pressed ? 0.9 : rowHover.hovered ? 0.6 : 0.3
            frameColor: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, tap.pressed || rowHover.hovered ? 0.8 : 0.3)
        }
        MouseArea {
            id: tap
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: action.pressed()
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 12
            spacing: 14

            Text {
                Layout.preferredWidth: 22
                horizontalAlignment: Text.AlignHCenter
                text: action.glyph
                color: Theme.accent
                font.family: Theme.font
                font.pixelSize: 20
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1

                Label {
                    text: action.label
                    font.pixelSize: 12
                    font.bold: true
                    font.letterSpacing: 1.5
                }
                Label {
                    Layout.fillWidth: true
                    text: action.hint
                    color: Theme.muted
                    font.pixelSize: 10
                    elide: Text.ElideRight
                }
            }
        }
    }
}
