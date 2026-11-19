// The bottom bar: two plates over the bottom edge, reserving space like the top bar. Media on the
// left (while a player is around), status readouts on the right.
import QtQuick
import QtQuick.Layouts
import Quickshell

PanelWindow {
    id: bar

    anchors {
        bottom: true
        left: true
        right: true
    }
    implicitHeight: Tablet.barHeight
    color: "transparent"

    Island {
        visible: Media.active !== null
        anchors.left: parent.left
        anchors.leftMargin: 8
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 6
        cutBottomLeft: 4
        cutTopRight: 14
        scale: Tablet.barScale
        transformOrigin: Item.BottomLeft

        MediaReadout {
            Layout.maximumWidth: bar.width * 0.3 / Tablet.barScale
        }
        Divider {
            visible: progress.visible
        }

        // Where the track is: a short segmented strip and the time.
        RowLayout {
            id: progress

            readonly property var player: Media.active
            readonly property real fraction: player && player.length > 0 ? Math.min(1, player.position / player.length) : 0

            visible: player?.lengthSupported ?? false
            spacing: 6

            Gauge {
                Layout.alignment: Qt.AlignVCenter
                segments: 16
                value: progress.fraction
                color: progress.player?.isPlaying ? Theme.accent : Theme.muted
            }
            Label {
                text: Media.time(progress.player?.position ?? 0) + " / " + Media.time(progress.player?.length ?? 0)
                color: Theme.dim
                font.pixelSize: 11
            }
        }
    }

    MediaPanel {
        screen: bar.screen
    }
    NetworkPanel {
        screen: bar.screen
    }
    AudioPanel {
        screen: bar.screen
    }
    BluetoothPanel {
        screen: bar.screen
    }
    DrivesPanel {
        screen: bar.screen
    }

    Island {
        anchors.right: parent.right
        anchors.rightMargin: 8
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 6
        cutBottomRight: 4
        cutTopLeft: 14
        stripRight: true
        scale: Tablet.barScale
        transformOrigin: Item.BottomRight

        // The OSD shows volume and brightness as they change, so here they're just numbers.
        Volume {
            showGauge: false
        }
        Brightness {
            showGauge: false
        }
        Network {}
        BluetoothReadout {}
        DrivesReadout {}
        PenReadout {}
        Battery {}
    }
}
