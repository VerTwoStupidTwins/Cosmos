// Edge swipes in tablet mode: thin touch strips along the built-in screen's edges, there only while
// the laptop is folded. A finger dragged in from an edge, far enough, does that edge's job:
// - top: open the notification log;
// - bottom: show or hide the on-screen keyboard;
// - left / right: the previous / next workspace.
// The top and bottom strips are only as tall as the gap above and below the bars' plates, so taps
// on the bars still land; a lit line on the strip shows how far the swipe has got.
import QtQuick
import Quickshell
import Quickshell.Wayland

Scope {
    id: root

    required property var screen
    // How far in a finger must travel for the swipe to count.
    readonly property int distance: 70

    component Edge: PanelWindow {
        id: edge

        // "top", "bottom", "left" or "right".
        required property string side
        // Room for a finger in a strip that blocks nothing, on the sides; at the top and bottom,
        // the gap outside the bars' plates.
        property int thickness: vertical ? 6 : 10
        property bool enabled: true
        readonly property bool vertical: side === "top" || side === "bottom"
        // How far the finger has come in, 0–1 of the distance.
        property real progress: 0

        signal swiped

        screen: root.screen
        visible: Tablet.active && enabled
        anchors.top: side !== "bottom"
        anchors.bottom: side !== "top"
        anchors.left: side !== "right"
        anchors.right: side !== "left"
        implicitWidth: thickness
        implicitHeight: thickness
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell-edge"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        color: "transparent"

        Rectangle {
            anchors.fill: parent
            color: Theme.accent
            opacity: edge.progress * 0.9
        }

        // Touch reaches it as mouse events; the surface keeps getting the finger's moves after it
        // leaves the strip, in the strip's own coordinates.
        MouseArea {
            id: touch

            property real startX: 0
            property real startY: 0
            property bool fired: false

            anchors.fill: parent
            preventStealing: true

            function inward(mouse) {
                switch (edge.side) {
                case "top": return mouse.y - startY;
                case "bottom": return startY - mouse.y;
                case "left": return mouse.x - startX;
                default: return startX - mouse.x;
                }
            }

            onPressed: mouse => {
                startX = mouse.x;
                startY = mouse.y;
                fired = false;
            }
            onPositionChanged: mouse => {
                if (fired) return;
                edge.progress = Math.max(0, Math.min(1, inward(mouse) / root.distance));
                if (edge.progress >= 1) {
                    fired = true;
                    edge.swiped();
                }
            }
            onReleased: edge.progress = 0
            onCanceled: edge.progress = 0
        }
    }

    Edge {
        side: "top"
        onSwiped: if (!Notifs.logOpen) Notifs.toggleLog()
    }
    Edge {
        side: "bottom"
        onSwiped: Tablet.toggleKeyboard()
    }
    Edge {
        side: "left"
        onSwiped: Quickshell.execDetached(["niri", "msg", "action", "focus-workspace-up"])
    }
    Edge {
        side: "right"
        // The pen menu sits by this edge while it's up.
        enabled: !Pen.menu
        onSwiped: Quickshell.execDetached(["niri", "msg", "action", "focus-workspace-down"])
    }
}
