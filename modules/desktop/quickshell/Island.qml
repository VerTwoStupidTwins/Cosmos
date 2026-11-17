// One of the bar's three plates. Children are laid out in a row.
import QtQuick
import QtQuick.Layouts

Item {
    id: root

    default property alias content: row.data
    property real cutTopLeft: 0
    property real cutTopRight: 0
    property real cutBottomRight: 0
    property real cutBottomLeft: 0
    property int padding: 16
    // Which end the status strip sits at.
    property bool stripRight: false

    implicitWidth: row.implicitWidth + padding * 2
    implicitHeight: 30

    PlateShape {
        anchors.fill: parent
        cutTopLeft: root.cutTopLeft
        cutTopRight: root.cutTopRight
        cutBottomRight: root.cutBottomRight
        cutBottomLeft: root.cutBottomLeft
        stripRight: root.stripRight
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 14
    }
}
