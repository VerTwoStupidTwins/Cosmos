// The focused window, over wlr-foreign-toplevel: the cockpit's current target.
import QtQuick
import QtQuick.Layouts
import Quickshell.Wayland

RowLayout {
    readonly property string title: ToplevelManager.activeToplevel?.title ?? ""

    spacing: 6

    Tag {
        text: "TGT"
    }
    Label {
        Layout.fillWidth: true
        Layout.preferredWidth: implicitWidth
        text: parent.title || "NO TARGET"
        color: parent.title ? Theme.fg : Theme.muted
        elide: Text.ElideRight
    }
}
