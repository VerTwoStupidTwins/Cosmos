// The application launcher: a RUN plate over a dimmed screen, with a search field and the
// matching apps below it. ↑/↓, Tab or Ctrl+J/K move, Enter launches, Esc or a click outside closes.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets

PanelWindow {
    id: launcher

    readonly property int rows: 8
    readonly property int rowHeight: 46
    property var results: []

    visible: Launcher.open
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-launcher"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    color: Qt.rgba(0, 0, 0, 0.45)

    function refresh() {
        results = Launcher.search(field.text);
        list.currentIndex = 0;
        list.positionViewAtBeginning();
    }
    function move(step) {
        if (results.length === 0) return;
        list.currentIndex = (list.currentIndex + step + results.length) % results.length;
    }
    function launchCurrent() {
        if (results.length > 0) Launcher.launch(results[list.currentIndex]);
    }

    onVisibleChanged: {
        if (visible) {
            field.text = "";
            refresh();
            field.forceActiveFocus();
        }
    }

    Connections {
        target: Launcher
        function onAppsChanged() {
            if (launcher.visible) launcher.refresh();
        }
    }

    // A click anywhere outside the plate closes it.
    MouseArea {
        anchors.fill: parent
        onClicked: Launcher.open = false
    }

    Plate {
        id: plate
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.round(parent.height * 0.18)
        width: 620
        title: "RUN"
        status: String(launcher.results.length).padStart(3, "0") + " / " + String(Launcher.apps.length).padStart(3, "0")
        cutTopLeft: 6
        cutTopRight: 6
        cutBottomLeft: 14
        cutBottomRight: 14
        padding: 14

        // Swallow clicks on the plate so they don't reach the backdrop.
        MouseArea {
            parent: plate
            anchors.fill: parent
            z: -1
        }

        // The search field: a prompt, the query and a block cursor in an angular slot.
        Item {
            Layout.fillWidth: true
            implicitHeight: 42

            PlateShape {
                anchors.fill: parent
                cutTopLeft: 8
                cutBottomRight: 8
                fillOpacity: 0.55
                showStrip: false
            }
            Label {
                id: prompt
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                text: ">"
                color: Theme.accent
                font.pixelSize: 16
                font.bold: true
            }
            TextInput {
                id: field
                anchors.left: prompt.right
                anchors.leftMargin: 10
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                color: Theme.fg
                font.family: Theme.font
                font.pixelSize: 15
                selectionColor: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.4)
                clip: true
                focus: true

                cursorDelegate: Rectangle {
                    width: 8
                    color: Theme.accent

                    SequentialAnimation on opacity {
                        loops: Animation.Infinite
                        NumberAnimation { to: 0; duration: 500; easing.type: Easing.InQuad }
                        NumberAnimation { to: 1; duration: 500; easing.type: Easing.OutQuad }
                    }
                }

                onTextChanged: launcher.refresh()
                onAccepted: launcher.launchCurrent()
                Keys.onEscapePressed: Launcher.open = false
                Keys.onUpPressed: launcher.move(-1)
                Keys.onDownPressed: launcher.move(1)
                Keys.onTabPressed: launcher.move(1)
                Keys.onBacktabPressed: launcher.move(-1)
                Keys.onPressed: event => {
                    const ctrl = event.modifiers & Qt.ControlModifier;
                    if (ctrl && (event.key === Qt.Key_J || event.key === Qt.Key_N)) {
                        launcher.move(1);
                        event.accepted = true;
                    } else if (ctrl && (event.key === Qt.Key_K || event.key === Qt.Key_P)) {
                        launcher.move(-1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_PageDown) {
                        launcher.move(launcher.rows);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_PageUp) {
                        launcher.move(-launcher.rows);
                        event.accepted = true;
                    }
                }
            }
            Label {
                anchors.left: field.left
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                visible: field.text.length === 0
                text: "SEARCH APPLICATIONS"
                color: Theme.muted
                font.pixelSize: 12
                font.letterSpacing: 3
            }
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.topMargin: 4
            implicitHeight: Math.min(launcher.results.length, launcher.rows) * launcher.rowHeight
            clip: true
            model: launcher.results
            boundsBehavior: Flickable.StopAtBounds
            highlightMoveDuration: 90

            delegate: Item {
                id: row

                required property var modelData
                required property int index
                readonly property bool current: ListView.isCurrentItem

                width: list.width
                height: launcher.rowHeight

                Rectangle {
                    anchors.fill: parent
                    anchors.topMargin: 2
                    anchors.bottomMargin: 2
                    color: row.current ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.14) : "transparent"
                }
                Rectangle {
                    visible: row.current
                    x: 0
                    y: 6
                    width: 3
                    height: parent.height - 12
                    color: Theme.accent
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 10
                    spacing: 12

                    Item {
                        implicitWidth: 28
                        implicitHeight: 28

                        // Absolute paths as they are; theme names when the theme has them.
                        IconImage {
                            id: icon
                            anchors.fill: parent
                            asynchronous: true
                            source: {
                                const name = row.modelData.icon;
                                if (name.startsWith("/")) return "file://" + name;
                                return Quickshell.iconPath(name, true);
                            }
                        }
                        // Without one, the app's initial in a frame.
                        Rectangle {
                            anchors.fill: parent
                            visible: icon.status !== Image.Ready
                            color: "transparent"
                            border.width: 1
                            border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.6)

                            Label {
                                anchors.centerIn: parent
                                text: row.modelData.name.charAt(0).toUpperCase()
                                color: Theme.accent
                                font.pixelSize: 14
                                font.bold: true
                            }
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1

                        Label {
                            Layout.fillWidth: true
                            text: row.modelData.name
                            color: row.current ? Theme.fg : Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.85)
                            font.pixelSize: 13
                            font.bold: row.current
                            elide: Text.ElideRight
                        }
                        Label {
                            Layout.fillWidth: true
                            visible: text !== ""
                            text: row.modelData.genericName || row.modelData.comment || ""
                            color: Theme.dim
                            font.family: Config.sans
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                    }
                    Label {
                        text: String(row.index + 1).padStart(2, "0")
                        color: row.current ? Theme.accent : Theme.muted
                        font.pixelSize: 10
                        font.letterSpacing: 1
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: list.currentIndex = row.index
                    onClicked: Launcher.launch(row.modelData)
                }
            }
        }

        Label {
            Layout.fillWidth: true
            Layout.topMargin: 2
            visible: launcher.results.length === 0
            text: "NO MATCH"
            color: Theme.muted
            font.pixelSize: 11
            font.letterSpacing: 3
            horizontalAlignment: Text.AlignHCenter
        }

        Label {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignRight
            text: "↑↓ SELECT  ·  ⏎ LAUNCH  ·  ESC CLOSE"
            color: Theme.muted
            font.pixelSize: 9
            font.letterSpacing: 2
        }
    }
}
