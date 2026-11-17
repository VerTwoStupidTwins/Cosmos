// A section of the command station: a plate with a HUD tag and a status reading in its header,
// and its children stacked below.
import QtQuick
import QtQuick.Layouts

Item {
    id: root

    default property alias content: body.data
    property string title
    property string status
    property color statusTone: Theme.dim
    property real cutTopLeft: 0
    property real cutTopRight: 0
    property real cutBottomRight: 10
    property real cutBottomLeft: 0
    property bool stripRight: false
    property int padding: 12

    implicitWidth: Math.max(header.implicitWidth, body.implicitWidth) + padding * 2
    implicitHeight: padding + header.implicitHeight + 8 + body.implicitHeight + padding

    PlateShape {
        anchors.fill: parent
        cutTopLeft: root.cutTopLeft
        cutTopRight: root.cutTopRight
        cutBottomRight: root.cutBottomRight
        cutBottomLeft: root.cutBottomLeft
        stripRight: root.stripRight
        fillOpacity: 0.92
    }

    RowLayout {
        id: header
        x: root.padding
        y: root.padding
        width: root.width - root.padding * 2
        spacing: 8

        Tag {
            text: root.title
        }
        Item {
            Layout.fillWidth: true
        }
        Label {
            text: root.status
            color: root.statusTone
            font.pixelSize: 11
            font.letterSpacing: 1
        }
    }

    ColumnLayout {
        id: body
        x: root.padding
        y: header.y + header.height + 8
        width: root.width - root.padding * 2
        spacing: 6
    }
}
