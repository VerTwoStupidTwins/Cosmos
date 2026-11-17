// The lock screen's password field: an angular slot that shows a square for each character
// typed and a blinking block cursor, never the text itself.
import QtQuick
import QtQuick.Layouts

Item {
    id: root

    property alias text: input.text
    property bool busy: false
    property bool failed: false

    signal accepted()

    function focusInput() {
        input.forceActiveFocus();
    }

    Layout.fillWidth: true
    implicitHeight: 42

    PlateShape {
        anchors.fill: parent
        cutTopLeft: 8
        cutBottomRight: 8
        fillOpacity: 0.55
        showStrip: false
        frameColor: root.failed ? Theme.urgent : Theme.accent
    }

    TextInput {
        id: input
        anchors.fill: parent
        opacity: 0
        echoMode: TextInput.Password
        cursorVisible: false
        readOnly: root.busy
        focus: true
        onAccepted: root.accepted()
        Keys.onEscapePressed: text = ""
    }

    Row {
        anchors.left: parent.left
        anchors.leftMargin: 16
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6

        Repeater {
            // Past a field's worth, more squares wouldn't tell anyone anything.
            model: Math.min(input.text.length, 28)

            Rectangle {
                width: 8
                height: 8
                anchors.verticalCenter: parent.verticalCenter
                color: root.failed ? Theme.urgent : Theme.accent
            }
        }

        Rectangle {
            visible: !root.busy
            width: 8
            height: 16
            color: Theme.accent

            SequentialAnimation on opacity {
                loops: Animation.Infinite
                running: !root.busy
                NumberAnimation { to: 0; duration: 500; easing.type: Easing.InQuad }
                NumberAnimation { to: 1; duration: 500; easing.type: Easing.OutQuad }
            }
        }
    }

    Label {
        anchors.left: parent.left
        anchors.leftMargin: 32
        anchors.verticalCenter: parent.verticalCenter
        visible: input.text.length === 0 && !root.busy
        text: "ENTER KEY"
        color: Theme.muted
        font.pixelSize: 12
        font.letterSpacing: 3
    }

    Label {
        anchors.right: parent.right
        anchors.rightMargin: 16
        anchors.verticalCenter: parent.verticalCenter
        text: root.busy ? "VERIFYING" : "⏎"
        color: root.busy ? Theme.warn : Theme.dim
        font.pixelSize: root.busy ? 10 : 14
        font.letterSpacing: root.busy ? 2 : 0

        SequentialAnimation on opacity {
            loops: Animation.Infinite
            running: root.busy
            NumberAnimation { to: 0.3; duration: 400 }
            NumberAnimation { to: 1; duration: 400 }
        }
    }
}
