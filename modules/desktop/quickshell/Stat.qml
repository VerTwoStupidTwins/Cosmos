// One line of a station plate: a dim key on the left, its reading on the right.
import QtQuick
import QtQuick.Layouts

RowLayout {
    id: root

    property string key
    property string value
    property color tone: Theme.fg

    Layout.fillWidth: true
    spacing: 8

    Label {
        text: root.key
        color: Theme.dim
        font.pixelSize: 10
        font.letterSpacing: 1.2
    }
    // A dotted leader between key and value, as on an instrument readout.
    Item {
        Layout.fillWidth: true
        implicitHeight: 1

        Row {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            clip: true
            spacing: 3

            Repeater {
                model: Math.max(0, Math.floor(parent.width / 4))

                Rectangle {
                    width: 1
                    height: 1
                    color: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.25)
                }
            }
        }
    }
    Label {
        text: root.value
        color: root.tone
        font.pixelSize: 12
    }
}
