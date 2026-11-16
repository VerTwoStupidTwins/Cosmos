// One of the bar's three plates: an angular panel with cut corners, a thin frame and a
// status strip, like a cockpit display. Children are laid out in a row.
import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes

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

    // The plate's outline, inset by half a pixel so a 1px stroke lands on whole pixels.
    readonly property var outline: {
        const o = 0.5, w = width - 0.5, h = height - 0.5;
        return [
            Qt.point(o + cutTopLeft, o), Qt.point(w - cutTopRight, o),
            Qt.point(w, o + cutTopRight), Qt.point(w, h - cutBottomRight),
            Qt.point(w - cutBottomRight, h), Qt.point(o + cutBottomLeft, h),
            Qt.point(o, h - cutBottomLeft), Qt.point(o, o + cutTopLeft),
            Qt.point(o + cutTopLeft, o)
        ];
    }

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        // A dark line around the frame, so the plate stands off any wallpaper. It is 3px
        // wide on the frame's path; the plate's fill covers the inner part, leaving 1px outside.
        ShapePath {
            fillColor: "transparent"
            strokeColor: Qt.rgba(0, 0, 0, 0.75)
            strokeWidth: 3
            joinStyle: ShapePath.MiterJoin

            PathPolyline {
                path: root.outline
            }
        }

        // The plate and its accent frame.
        ShapePath {
            fillColor: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0.9)
            strokeColor: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.6)
            strokeWidth: 1
            joinStyle: ShapePath.MiterJoin

            PathPolyline {
                path: root.outline
            }
        }
    }

    // Status strip along the top edge, with a short tick beside it.
    Row {
        y: -1
        x: root.stripRight ? root.width - root.cutTopRight - width - 10 : root.cutTopLeft + 10
        spacing: 3
        layoutDirection: root.stripRight ? Qt.RightToLeft : Qt.LeftToRight

        Rectangle { width: 26; height: 3; color: Theme.accent }
        Rectangle { width: 5; height: 3; color: Theme.accent; opacity: 0.5 }
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 14
    }
}
