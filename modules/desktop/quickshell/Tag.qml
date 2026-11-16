// A boxed HUD label: VOL, PWR, TGT…
import QtQuick

Rectangle {
    property alias text: label.text

    implicitWidth: label.implicitWidth + 8
    implicitHeight: 14
    color: "transparent"
    border.width: 1
    border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.7)

    Text {
        id: label
        anchors.centerIn: parent
        color: Theme.accent
        font.family: Theme.font
        font.pixelSize: 9
        font.bold: true
        font.letterSpacing: 1.2
    }
}
