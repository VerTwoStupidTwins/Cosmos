// Three plates floating over the top edge: workspaces and target window on the left, the
// clock in the centre, status readouts on the right.
import QtQuick
import QtQuick.Layouts
import Quickshell

PanelWindow {
    id: bar

    anchors {
        top: true
        left: true
        right: true
    }
    implicitHeight: 40
    color: "transparent"

    Island {
        anchors.left: parent.left
        anchors.leftMargin: 8
        y: 6
        cutTopLeft: 4
        cutBottomRight: 14

        Workspaces {}
        Divider {}
        WindowTitle {
            Layout.maximumWidth: bar.width * 0.28
        }
    }

    Island {
        id: centre
        anchors.horizontalCenter: parent.horizontalCenter
        y: 6
        cutBottomLeft: 14
        cutBottomRight: 14

        Clock {}

        // Clicking the clock opens the command station below it.
        MouseArea {
            parent: centre
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: Station.toggle()
        }
    }

    StationPanel {
        screen: bar.screen
    }

    Island {
        anchors.right: parent.right
        anchors.rightMargin: 8
        y: 6
        cutTopRight: 4
        cutBottomLeft: 14
        stripRight: true

        Tray {
            bar: bar
        }
        Volume {}
        Brightness {}
        Network {}
        Battery {}
    }
}
