// Tag, gauge and value in a row, the shape every status readout takes. Clicks and scrolls are
// passed on as pressed(button) and scrolled(delta).
import QtQuick
import QtQuick.Layouts

Item {
    id: root

    property string tag
    property real value: 0
    property int segments: 10
    property bool showGauge: true
    property string reading
    property color tone: Theme.accent

    signal pressed(int button)
    signal scrolled(int delta)

    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight

    RowLayout {
        id: row
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6

        Tag {
            text: root.tag
        }
        Gauge {
            visible: root.showGauge
            value: root.value
            segments: root.segments
            color: root.tone
        }
        Label {
            text: root.reading
            color: root.tone === Theme.accent ? Theme.fg : root.tone
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onClicked: mouse => root.pressed(mouse.button)
        onWheel: wheel => root.scrolled(wheel.angleDelta.y)
    }
}
