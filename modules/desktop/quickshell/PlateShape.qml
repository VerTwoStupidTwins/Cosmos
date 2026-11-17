// The cockpit plate every panel is drawn on: an angular shape with cut corners, a thin accent
// frame with a dark line outside it, and a status strip along the top edge.
import QtQuick
import QtQuick.Shapes

Item {
    id: root

    property real cutTopLeft: 0
    property real cutTopRight: 0
    property real cutBottomRight: 0
    property real cutBottomLeft: 0
    // Which end the status strip sits at.
    property bool stripRight: false
    property real fillOpacity: 0.9
    property bool showStrip: true
    property color frameColor: Theme.accent

    // The outline, inset by half a pixel so a 1px stroke lands on whole pixels.
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
            fillColor: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, root.fillOpacity)
            strokeColor: Qt.rgba(root.frameColor.r, root.frameColor.g, root.frameColor.b, 0.6)
            strokeWidth: 1
            joinStyle: ShapePath.MiterJoin

            PathPolyline {
                path: root.outline
            }
        }
    }

    // Status strip along the top edge, with a short tick beside it.
    Row {
        visible: root.showStrip
        y: -1
        x: root.stripRight ? root.width - root.cutTopRight - width - 10 : root.cutTopLeft + 10
        spacing: 3
        layoutDirection: root.stripRight ? Qt.RightToLeft : Qt.LeftToRight

        Rectangle { width: 26; height: 3; color: Theme.accent }
        Rectangle { width: 5; height: 3; color: Theme.accent; opacity: 0.5 }
    }
}
