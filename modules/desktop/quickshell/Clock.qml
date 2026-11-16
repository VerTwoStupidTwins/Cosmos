// SYS · MON 16 NOV · 11:12 with the seconds ticking beside it.
import QtQuick
import QtQuick.Layouts
import Quickshell

RowLayout {
    spacing: 8

    SystemClock {
        id: clock
        precision: SystemClock.Seconds
    }

    Tag {
        text: "SYS"
    }
    Label {
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
        Layout.alignment: Qt.AlignBottom
        Layout.bottomMargin: 1
        text: Qt.formatDateTime(clock.date, "ss")
        color: Theme.accent
        font.pixelSize: 10
    }
}
