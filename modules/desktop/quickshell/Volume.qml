// The default output. Scroll to change the volume, right click to mute, left click for the audio
// plate, middle click for pavucontrol.
import QtQuick
import Quickshell
import Quickshell.Services.Pipewire

Readout {
    id: root

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property bool ready: sink?.audio != null
    readonly property real volume: ready ? sink.audio.volume : 0
    readonly property bool muted: !ready || sink.audio.muted

    tag: "VOL"
    value: muted ? 0 : volume
    reading: muted ? "MUTE" : String(Math.round(volume * 100)).padStart(3, "0")
    tone: muted ? Theme.muted : Theme.accent

    // Pipewire only fills in a node's audio properties while something tracks it.
    PwObjectTracker {
        objects: root.sink ? [root.sink] : []
    }

    onPressed: button => {
        if (button === Qt.RightButton) {
            if (root.ready) root.sink.audio.muted = !root.sink.audio.muted;
        } else if (button === Qt.LeftButton) {
            Panels.toggle("audio");
        } else if (button === Qt.MiddleButton) {
            Quickshell.execDetached([Config.pavucontrol]);
        }
    }
    onScrolled: delta => {
        if (!root.ready) return;
        root.sink.audio.volume = Math.max(0, Math.min(1, root.volume + (delta > 0 ? 0.05 : -0.05)));
    }
}
