// The bar's media readout: play state and "title · artist" for the player Media follows. A click
// opens the media plate; a right click plays or pauses.
import QtQuick
import QtQuick.Layouts

Item {
    id: root

    readonly property var player: Media.active
    readonly property string track: {
        if (!player) return "";
        const title = player.trackTitle || player.identity;
        return player.trackArtist ? title + " · " + player.trackArtist : title;
    }

    visible: player !== null
    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight

    RowLayout {
        id: row
        anchors.verticalCenter: parent.verticalCenter
        width: root.width
        spacing: 6

        Tag {
            text: "MED"
        }
        Text {
            text: root.player?.isPlaying ? "󰐊" : "󰏤"
            color: root.player?.isPlaying ? Theme.accent : Theme.muted
            font.family: Theme.font
            font.pixelSize: 12
        }
        Label {
            Layout.fillWidth: true
            Layout.preferredWidth: implicitWidth
            Layout.maximumWidth: 200
            text: root.track
            color: root.player?.isPlaying ? Theme.fg : Theme.dim
            elide: Text.ElideRight
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton) root.player?.togglePlaying();
            else Media.toggle();
        }
    }
}
