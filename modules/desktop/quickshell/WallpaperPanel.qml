// The wallpaper picker: a grid of the repo's wallpapers over a dimmed screen, each with its palette
// (the cached one a rebuild made; wallpapers added since get theirs from matugen when picked).
// Arrows or hover move, Enter or a click sets it through `wallpaper`, Esc or a click outside closes.
import QtQuick
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

PanelWindow {
    id: picker

    readonly property int columns: 3
    readonly property int tileWidth: 232
    readonly property int tileHeight: 172
    property string current: ""

    visible: Wallpapers.open
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-wallpaper"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    color: Qt.rgba(0, 0, 0, 0.45)

    function apply(path) {
        setter.command = [Config.wallpaperCommand, path];
        setter.running = true;
        Wallpapers.open = false;
    }

    onVisibleChanged: {
        if (!visible) return;
        currentFile.reload();
        grid.forceActiveFocus();
    }

    Process {
        id: setter
    }

    FileView {
        id: currentFile
        path: Config.wallpaperCurrent
        printErrors: false
        onLoaded: {
            picker.current = text().trim();
            for (let i = 0; i < images.count; i++) {
                if (images.get(i, "filePath") === picker.current) grid.currentIndex = i;
            }
        }
    }

    FolderListModel {
        id: images
        folder: "file://" + Config.wallpaperDir
        nameFilters: ["*.png", "*.jpg", "*.jpeg", "*.webp", "*.PNG", "*.JPG", "*.JPEG", "*.WEBP"]
        showDirs: false
        sortField: FolderListModel.Name
    }

    MouseArea {
        anchors.fill: parent
        onClicked: Wallpapers.open = false
    }

    Plate {
        id: plate
        anchors.centerIn: parent
        title: "WALLPAPER"
        status: String(images.count).padStart(2, "0") + " IMAGES"
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

        GridView {
            id: grid
            implicitWidth: picker.columns * picker.tileWidth
            implicitHeight: Math.min(Math.ceil(images.count / picker.columns), 3) * picker.tileHeight
            cellWidth: picker.tileWidth
            cellHeight: picker.tileHeight
            clip: true
            model: images
            boundsBehavior: Flickable.StopAtBounds
            keyNavigationWraps: true
            focus: true

            Keys.onEscapePressed: Wallpapers.open = false
            Keys.onReturnPressed: picker.apply(images.get(currentIndex, "filePath"))
            Keys.onEnterPressed: picker.apply(images.get(currentIndex, "filePath"))

            delegate: Item {
                id: tile

                required property string filePath
                required property string fileName
                required property int index
                readonly property bool selected: GridView.isCurrentItem
                readonly property bool active: filePath === picker.current
                readonly property var palette: {
                    try {
                        const p = JSON.parse(paletteFile.text()).base16;
                        return ["base08", "base09", "base0a", "base0b", "base0c", "base0d", "base0e", "base0f"].map(k => p[k].default.color);
                    } catch (e) {
                        return [];
                    }
                }

                width: picker.tileWidth
                height: picker.tileHeight

                FileView {
                    id: paletteFile
                    path: Config.wallpaperLibrary + "/" + tile.fileName + ".palette.json"
                    printErrors: false
                    blockLoading: true
                }

                Item {
                    anchors.fill: parent
                    anchors.margins: 6

                    PlateShape {
                        anchors.fill: parent
                        cutTopLeft: 8
                        cutBottomRight: 8
                        fillOpacity: tile.selected ? 0.9 : 0.5
                        showStrip: false
                        frameColor: tile.selected ? Theme.accent : Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.35)
                    }

                    Image {
                        id: thumb
                        x: 6
                        y: 6
                        width: parent.width - 12
                        height: Math.round(width * 9 / 16)
                        source: "file://" + tile.filePath
                        sourceSize.width: width * 2
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: true
                        opacity: tile.selected || tile.active ? 1 : 0.7

                        Behavior on opacity {
                            NumberAnimation { duration: 120 }
                        }
                    }
                    Tag {
                        visible: tile.active
                        anchors.top: thumb.top
                        anchors.right: thumb.right
                        anchors.margins: 6
                        text: "ACTIVE"
                        color: Qt.rgba(0, 0, 0, 0.6)
                    }

                    // The palette, as a strip of swatches, or a note when it comes at pick time.
                    Row {
                        id: swatches
                        anchors.top: thumb.bottom
                        anchors.topMargin: 6
                        x: 6
                        spacing: 2
                        visible: tile.palette.length > 0

                        Repeater {
                            model: tile.palette

                            Rectangle {
                                required property string modelData
                                width: 10
                                height: 6
                                color: modelData
                            }
                        }
                    }
                    Label {
                        anchors.verticalCenter: swatches.verticalCenter
                        x: 6
                        visible: tile.palette.length === 0
                        text: "NEW · MATUGEN"
                        color: Theme.muted
                        font.pixelSize: 8
                        font.letterSpacing: 1
                    }
                    Label {
                        anchors.top: swatches.bottom
                        anchors.topMargin: 4
                        x: 6
                        width: parent.width - 12
                        text: tile.fileName.replace(/\.[^.]+$/, "").replace(/[_-]+/g, " ").toUpperCase()
                        color: tile.selected ? Theme.fg : Theme.dim
                        font.pixelSize: 10
                        font.bold: tile.selected
                        font.letterSpacing: 1
                        elide: Text.ElideRight
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: grid.currentIndex = tile.index
                    onClicked: picker.apply(tile.filePath)
                }
            }
        }

        Label {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignRight
            text: "←↑↓→ SELECT  ·  ⏎ SET  ·  ESC CLOSE"
            color: Theme.muted
            font.pixelSize: 9
            font.letterSpacing: 2
        }
    }
}
