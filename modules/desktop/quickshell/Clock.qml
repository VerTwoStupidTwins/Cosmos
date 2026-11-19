// SYS · MON 16 NOV · 11:12 with the seconds ticking beside it; just the time when compact.
import QtQuick
import QtQuick.Layouts
import Quickshell

RowLayout {
    property bool compact: false

    spacing: 8

    SystemClock {
        id: clock
        precision: SystemClock.Seconds
    }

    Tag {
        visible: !parent.compact
        text: "SYS"
    }
    Label {
        visible: !parent.compact
        text: Qt.formatDateTime(clock.date, "ddd dd MMM").toUpperCase()
        color: Theme.dim
        font.letterSpacing: 1
    }
    Label {
        text: Qt.formatDateTime(clock.date, "HH:mm")
        font.pixelSize: 16
        font.bold: true
    }
    Label {
        visible: !parent.compact
        Layout.alignment: Qt.AlignBottom
        Layout.bottomMargin: 1
        text: Qt.formatDateTime(clock.date, "ss")
        color: Theme.accent
        font.pixelSize: 10
    }
}
