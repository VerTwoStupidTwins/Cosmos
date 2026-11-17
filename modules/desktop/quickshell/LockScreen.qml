// What a screen shows while locked: the wallpaper blurred and dimmed behind faint scanlines, a large
// clock, the AUTH plate with the password field, and power and link readouts at the bottom. Kept apart
// from LockSurface so it can be previewed in an ordinary window.
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell

Item {
    id: surface

    required property var lock

    SystemClock {
        id: clock
        precision: SystemClock.Seconds
    }

    Image {
        id: wallpaper
        anchors.fill: parent
        source: "file://" + Config.wallpaper
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        visible: false
    }

    MultiEffect {
        anchors.fill: parent
        source: wallpaper
        blurEnabled: true
        blur: 1
        blurMax: 48
        brightness: -0.45
        saturation: -0.25
    }

    // Scanlines, as on a display.
    Column {
        anchors.fill: parent

        Repeater {
            model: Math.ceil(surface.height / 3)

            Item {
                width: surface.width
                height: 3

                Rectangle {
                    width: parent.width
                    height: 1
                    color: Qt.rgba(0, 0, 0, 0.18)
                }
            }
        }
    }

    // Corner readouts.
    Label {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: 24
        text: "COSMOS // " + Station.hostname.toUpperCase()
        color: Theme.dim
        font.pixelSize: 11
        font.letterSpacing: 3
    }
    Row {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 24
        spacing: 8

        Rectangle {
            width: 8
            height: 8
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.urgent

            SequentialAnimation on opacity {
                loops: Animation.Infinite
                NumberAnimation { to: 0.2; duration: 700 }
                NumberAnimation { to: 1; duration: 700 }
            }
        }
        Label {
            text: "SESSION LOCKED"
            color: Theme.accent
            font.pixelSize: 11
            font.letterSpacing: 3
        }
    }

    ColumnLayout {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -20
        spacing: 26

        // The clock: SYS tag, the time with its seconds, and the date.
        ColumnLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 2

            Tag {
                Layout.alignment: Qt.AlignHCenter
                text: "SYS"
            }
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 6

                Label {
                    text: Qt.formatDateTime(clock.date, "HH:mm")
                    font.pixelSize: 88
                    font.bold: true
                    font.letterSpacing: 2
                }
                Label {
                    Layout.alignment: Qt.AlignBottom
                    Layout.bottomMargin: 18
                    text: Qt.formatDateTime(clock.date, "ss")
                    color: Theme.accent
                    font.pixelSize: 22
                }
            }
            Label {
                Layout.alignment: Qt.AlignHCenter
                text: Qt.formatDateTime(clock.date, "dddd dd MMMM yyyy").toUpperCase()
                color: Theme.dim
                font.pixelSize: 13
                font.letterSpacing: 4
            }
        }

        Plate {
            id: auth
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 460
            title: "AUTH"
            status: surface.lock.busy ? "VERIFYING" : surface.lock.failed ? "DENIED" : "LOCKED"
            statusTone: surface.lock.busy ? Theme.warn : surface.lock.failed ? Theme.urgent : Theme.dim
            cutTopLeft: 6
            cutBottomRight: 18
            cutBottomLeft: 6
            padding: 16

            // Shakes when a key is refused.
            transform: Translate {
                id: shake
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 2
                spacing: 10

                Label {
                    text: Station.hostname.toUpperCase()
                    color: Theme.accent
                    font.pixelSize: 24
                    font.bold: true
                    font.letterSpacing: 4
                }
                Label {
                    text: "// SECURE TERMINAL"
                    color: Theme.dim
                    font.pixelSize: 11
                    font.letterSpacing: 2
                }
            }
            Stat {
                key: "OPERATOR"
                value: Quickshell.env("USER")
            }
            KeyField {
                id: field
                Layout.topMargin: 6
                busy: surface.lock.busy
                failed: surface.lock.failed
                onTextChanged: {
                    if (surface.lock.text !== text) surface.lock.text = text;
                    if (text.length > 0) surface.lock.failed = false;
                }
                onAccepted: surface.lock.submit()
                Component.onCompleted: focusInput()
            }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
                text: surface.lock.message
                    ? surface.lock.message + (surface.lock.attempts > 0 ? "  ·  ATTEMPT " + String(surface.lock.attempts).padStart(2, "0") : "")
                    : "AWAITING KEY"
                color: surface.lock.message ? Theme.urgent : Theme.muted
                font.pixelSize: 10
                font.letterSpacing: 2
            }
        }
    }

    Connections {
        target: surface.lock

        function onTextChanged() {
            if (field.text !== surface.lock.text) field.text = surface.lock.text;
        }
        function onAttemptsChanged() {
            if (surface.lock.attempts > 0) shakeAnimation.restart();
        }
    }

    SequentialAnimation {
        id: shakeAnimation
        NumberAnimation { target: shake; property: "x"; to: -12; duration: 50 }
        NumberAnimation { target: shake; property: "x"; to: 10; duration: 70 }
        NumberAnimation { target: shake; property: "x"; to: -6; duration: 70 }
        NumberAnimation { target: shake; property: "x"; to: 0; duration: 60 }
    }

    Island {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 28
        cutTopLeft: 14
        cutTopRight: 14

        Battery {}
        Network {}
    }
}
