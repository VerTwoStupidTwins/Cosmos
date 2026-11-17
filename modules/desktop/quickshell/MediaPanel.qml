// The media plate: rises over the bottom bar's left plate with the track's art, title, artist and
// album, a seekable progress strip, and previous / play-pause / next, plus shuffle and loop where
// the player has them. With more than one player, the header's tag switches between them.
// Click the bottom bar's MED readout, or run `qs -c bar ipc call media toggle`; Esc closes.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Mpris

PanelWindow {
    id: panel

    readonly property var player: Media.active

    visible: Media.open && player !== null
    anchors.bottom: true
    anchors.left: true
    margins.bottom: 42
    margins.left: 8
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-media"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    color: "transparent"

    implicitWidth: 420
    implicitHeight: plate.implicitHeight + 4

    onVisibleChanged: if (visible) keys.forceActiveFocus()

    Item {
        id: keys
        focus: true
        Keys.onEscapePressed: Media.open = false
        Keys.onSpacePressed: panel.player?.togglePlaying()
        Keys.onLeftPressed: panel.player?.previous()
        Keys.onRightPressed: panel.player?.next()
    }

    Plate {
        id: plate
        width: parent.width
        title: "MEDIA"
        status: panel.player ? panel.player.identity.toUpperCase() + (Media.players.length > 1 ? "  ·  " + (Media.players.indexOf(panel.player) + 1) + "/" + Media.players.length : "") : ""
        cutTopRight: 14
        cutBottomLeft: 4
        cutBottomRight: 10
        padding: 14

        // Clicking the header switches players.
        MouseArea {
            parent: plate
            x: 0
            y: 0
            width: plate.width
            height: 30
            enabled: Media.players.length > 1
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: Media.cycle()
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 14

            // The art, framed like a display inset, or the player's initial without any.
            Item {
                Layout.alignment: Qt.AlignTop
                implicitWidth: 104
                implicitHeight: 104

                PlateShape {
                    anchors.fill: parent
                    cutTopLeft: 8
                    cutBottomRight: 8
                    fillOpacity: 0.5
                    showStrip: false
                }
                Image {
                    id: art
                    anchors.fill: parent
                    anchors.margins: 5
                    source: panel.player?.trackArtUrl ?? ""
                    sourceSize.width: 208
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    visible: status === Image.Ready
                }
                Text {
                    anchors.centerIn: parent
                    visible: art.status !== Image.Ready
                    text: "󰝚"
                    color: Theme.muted
                    font.family: Theme.font
                    font.pixelSize: 36
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                spacing: 4

                Label {
                    Layout.fillWidth: true
                    text: panel.player?.trackTitle || "NOTHING PLAYING"
                    color: panel.player?.trackTitle ? Theme.fg : Theme.muted
                    font.pixelSize: 14
                    font.bold: true
                    elide: Text.ElideRight
                }
                Label {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: panel.player?.trackArtist ?? ""
                    color: Theme.accent
                    font.pixelSize: 12
                    elide: Text.ElideRight
                }
                Label {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: panel.player?.trackAlbum ?? ""
                    color: Theme.dim
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
                Item {
                    Layout.fillHeight: true
                }

                // The controls.
                RowLayout {
                    Layout.topMargin: 6
                    spacing: 6

                    MediaButton {
                        glyph: "󰒟"
                        visible: panel.player?.shuffleSupported ?? false
                        lit: panel.player?.shuffle ?? false
                        onClicked: panel.player.shuffle = !panel.player.shuffle
                    }
                    MediaButton {
                        glyph: "󰒮"
                        enabled: panel.player?.canGoPrevious ?? false
                        onClicked: panel.player.previous()
                    }
                    MediaButton {
                        glyph: panel.player?.isPlaying ? "󰏤" : "󰐊"
                        size: 34
                        lit: true
                        enabled: panel.player?.canTogglePlaying ?? false
                        onClicked: panel.player.togglePlaying()
                    }
                    MediaButton {
                        glyph: "󰒭"
                        enabled: panel.player?.canGoNext ?? false
                        onClicked: panel.player.next()
                    }
                    MediaButton {
                        readonly property int loop: panel.player?.loopState ?? MprisLoopState.None
                        glyph: loop === MprisLoopState.Track ? "󰑘" : "󰑖"
                        visible: panel.player?.loopSupported ?? false
                        lit: loop !== MprisLoopState.None
                        onClicked: panel.player.loopState = loop === MprisLoopState.None ? MprisLoopState.Playlist
                            : loop === MprisLoopState.Playlist ? MprisLoopState.Track : MprisLoopState.None
                    }
                }
            }
        }

        // Progress: a strip of segments lit up to the position, with the times either side.
        // Click or drag along it to seek.
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 4
            spacing: 10
            visible: panel.player?.lengthSupported ?? false

            Label {
                text: Media.time(panel.player?.position ?? 0)
                color: Theme.dim
                font.pixelSize: 10
            }
            Item {
                id: track
                Layout.fillWidth: true
                implicitHeight: 12

                readonly property real fraction: panel.player && panel.player.length > 0 ? Math.min(1, panel.player.position / panel.player.length) : 0
                readonly property int segments: Math.floor(width / 5)

                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Repeater {
                        model: track.segments

                        Rectangle {
                            required property int index
                            width: 3
                            height: 8
                            color: index < Math.round(track.fraction * track.segments) ? Theme.accent : Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.15)
                        }
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    enabled: panel.player?.canSeek ?? false
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    function seekTo(x) {
                        panel.player.position = Math.max(0, Math.min(1, x / width)) * panel.player.length;
                    }
                    onPressed: mouse => seekTo(mouse.x)
                    onPositionChanged: mouse => { if (pressed) seekTo(mouse.x); }
                }
            }
            Label {
                text: Media.time(panel.player?.length ?? 0)
                color: Theme.dim
                font.pixelSize: 10
            }
        }
    }

    component MediaButton: Item {
        id: button

        property string glyph
        property int size: 26
        property bool lit: false
        signal clicked

        implicitWidth: size
        implicitHeight: size
        opacity: enabled ? 1 : 0.35

        PlateShape {
            anchors.fill: parent
            cutTopLeft: button.size / 5
            cutBottomRight: button.size / 5
            fillOpacity: press.containsMouse ? 0.8 : 0.4
            showStrip: false
            frameColor: button.lit ? Theme.accent : Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.4)
        }
        Text {
            anchors.centerIn: parent
            text: button.glyph
            color: button.lit ? Theme.accent : Theme.fg
            font.family: Theme.font
            font.pixelSize: button.size * 0.5
        }
        MouseArea {
            id: press
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: button.clicked()
        }
    }
}
