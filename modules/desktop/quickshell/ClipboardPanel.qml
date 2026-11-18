// Clipboard history over cliphist (which the cliphist service fills from every copy): a CLIP plate
// over a dimmed screen with a search field and the recent entries, images as thumbnails. Enter or
// a click copies one back; Delete removes the selected one. ↑/↓ move, Esc or a click outside
// closes. Mod+Ctrl+V, or `qs -c bar ipc call clipboard toggle`.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

PanelWindow {
    id: history

    readonly property int rows: 8
    readonly property string thumbs: Quickshell.cachePath("clipboard")
    // Every entry as { id, text, image, line }, newest first, and those matching the search.
    property var entries: []
    property var results: []

    function refresh() {
        const q = field.text.trim().toLowerCase();
        results = q === "" ? entries.slice() : entries.filter(e => !e.image && e.text.toLowerCase().includes(q));
        list.currentIndex = 0;
        list.positionViewAtBeginning();
    }
    function move(step) {
        if (results.length > 0) list.currentIndex = (list.currentIndex + step + results.length) % results.length;
    }
    function run(script, env) {
        Quickshell.execDetached({ command: [Config.bash, "-c", script], environment: env });
    }
    function copy(entry) {
        run('"$CLIPHIST" decode "$ID" | "$WLCOPY"', { CLIPHIST: Config.cliphist, WLCOPY: Config.wlCopy, ID: entry.id });
        Panels.clipboard = false;
    }
    function remove(entry) {
        run('printf "%s" "$LINE" | "$CLIPHIST" delete', { CLIPHIST: Config.cliphist, LINE: entry.line });
        entries = entries.filter(e => e !== entry);
        const i = list.currentIndex;
        refresh();
        list.currentIndex = Math.min(i, results.length - 1);
    }

    visible: Panels.clipboard
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-clipboard"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    color: Qt.rgba(0, 0, 0, 0.45)

    onVisibleChanged: {
        if (!visible) return;
        field.text = "";
        entries = [];
        refresh();
        lister.running = true;
        field.forceActiveFocus();
    }

    // The history, then thumbnails for the first images that don't have one yet.
    Process {
        id: lister
        command: [Config.cliphist, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                history.entries = text.split("\n").filter(l => l.includes("\t")).map(line => {
                    const tab = line.indexOf("\t");
                    const id = line.slice(0, tab), body = line.slice(tab + 1);
                    const image = /^\[\[ binary data .* (png|jpe?g|webp|bmp|gif) /.test(body);
                    return { id: id, text: body, image: image, line: line };
                });
                history.refresh();
                const ids = history.entries.filter(e => e.image).slice(0, 30).map(e => e.id).join(" ");
                if (ids !== "") {
                    thumbnailer.environment = { CLIPHIST: Config.cliphist, DIR: history.thumbs, IDS: ids };
                    thumbnailer.running = true;
                }
            }
        }
    }
    Process {
        id: thumbnailer
        command: [Config.bash, "-c", 'mkdir -p "$DIR"; for id in $IDS; do [ -s "$DIR/$id.png" ] || "$CLIPHIST" decode "$id" > "$DIR/$id.png" < /dev/null; done']
        // Rebuilding the list makes the rows load the thumbnails just written.
        onExited: history.refresh()
    }

    MouseArea {
        anchors.fill: parent
        onClicked: Panels.clipboard = false
    }

    Plate {
        id: plate
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.round(parent.height * 0.18)
        width: 620
        title: "CLIP"
        status: String(history.results.length).padStart(3, "0") + " / " + String(history.entries.length).padStart(3, "0")
        cutTopLeft: 6
        cutTopRight: 6
        cutBottomLeft: 14
        cutBottomRight: 14
        padding: 14

        MouseArea {
            parent: plate
            anchors.fill: parent
            z: -1
        }

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
                clip: true
                focus: true
                cursorDelegate: Rectangle {
                    width: 8
                    color: Theme.accent
                }

                onTextChanged: history.refresh()
                onAccepted: if (history.results.length > 0) history.copy(history.results[list.currentIndex])
                Keys.onEscapePressed: Panels.clipboard = false
                Keys.onUpPressed: history.move(-1)
                Keys.onDownPressed: history.move(1)
                Keys.onTabPressed: history.move(1)
                Keys.onBacktabPressed: history.move(-1)
                Keys.onDeletePressed: event => {
                    // Delete removes the selected entry once the search is empty or at its end.
                    if (history.results.length > 0 && cursorPosition === text.length) {
                        history.remove(history.results[list.currentIndex]);
                        event.accepted = true;
                    } else {
                        event.accepted = false;
                    }
                }
            }
            Label {
                anchors.left: field.left
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                visible: field.text.length === 0
                text: "SEARCH CLIPBOARD"
                color: Theme.muted
                font.pixelSize: 12
                font.letterSpacing: 3
            }
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.topMargin: 4
            implicitHeight: Math.min(contentHeight, 420)
            clip: true
            spacing: 2
            model: history.results
            boundsBehavior: Flickable.StopAtBounds
            highlightMoveDuration: 90

            delegate: Item {
                id: row

                required property var modelData
                required property int index
                readonly property bool current: ListView.isCurrentItem

                width: list.width
                height: modelData.image ? 84 : 36

                Rectangle {
                    anchors.fill: parent
                    color: row.current ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.14) : "transparent"
                }
                Rectangle {
                    visible: row.current
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

                    Image {
                        visible: row.modelData.image
                        Layout.preferredWidth: 128
                        Layout.preferredHeight: 72
                        source: row.modelData.image ? "file://" + history.thumbs + "/" + row.modelData.id + ".png" : ""
                        sourceSize.width: 256
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        cache: false
                    }
                    Label {
                        Layout.fillWidth: true
                        text: row.modelData.image ? row.modelData.text.replace(/^\[\[ binary data /, "").replace(/ \]\]$/, "").toUpperCase()
                            : row.modelData.text.replace(/\s+/g, " ")
                        color: row.current ? Theme.fg : Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.8)
                        font.family: row.modelData.image ? Theme.font : Config.sans
                        font.pixelSize: row.modelData.image ? 10 : 12
                        elide: Text.ElideRight
                    }
                    // Remove this one.
                    Text {
                        visible: hover.hovered || row.current
                        text: "×"
                        color: del.containsMouse ? Theme.urgent : Theme.muted
                        font.family: Theme.font
                        font.pixelSize: 14

                        MouseArea {
                            id: del
                            anchors.fill: parent
                            anchors.margins: -4
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: history.remove(row.modelData)
                        }
                    }
                }

                HoverHandler {
                    id: hover
                }
                MouseArea {
                    anchors.fill: parent
                    z: -1
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: list.currentIndex = row.index
                    onClicked: history.copy(row.modelData)
                }
            }
        }

        Label {
            Layout.fillWidth: true
            visible: history.results.length === 0
            text: lister.running ? "LOADING…" : history.entries.length === 0 ? "NOTHING COPIED YET" : "NO MATCH"
            color: Theme.muted
            font.pixelSize: 11
            font.letterSpacing: 3
            horizontalAlignment: Text.AlignHCenter
        }

        Label {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignRight
            text: "↑↓ SELECT  ·  ⏎ COPY  ·  DEL REMOVE  ·  ESC CLOSE"
            color: Theme.muted
            font.pixelSize: 9
            font.letterSpacing: 2
        }
    }
}
