// The on-screen display: a plate low in the middle of the screen that shows volume, the mic's mute
// and brightness as they change, then fades. Volume and the mic are watched through PipeWire, so
// keys, the bar and pavucontrol all show it; brightness changes go through logind, which leaves no
// trace to watch, so the brightness keys call `qs -c bar ipc call osd brightness` after setting it.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pipewire

PanelWindow {
    id: osd

    readonly property int segments: 20
    // What it shows: "vol", "mic" or "brt", and the level (0–1) for the gauge.
    property string kind: "vol"
    property real level: 0
    property bool muted: false
    property bool shown: false

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var source: Pipewire.defaultAudioSource

    function show(what, value, isMuted) {
        kind = what;
        level = Math.max(0, Math.min(1, value));
        muted = isMuted;
        shown = true;
        hide.restart();
    }

    function showVolume() {
        if (!settled.done || !sink?.audio) return;
        show("vol", sink.audio.volume, sink.audio.muted);
    }
    function showMic() {
        if (!settled.done || !source?.audio) return;
        show("mic", source.audio.muted ? 0 : 1, source.audio.muted);
    }

    // It stays up a moment after hiding, for the fade.
    visible: shown || linger.running
    onShownChanged: if (!shown) linger.restart()
    anchors.bottom: true
    margins.bottom: 96
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-osd"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    color: "transparent"
    // Clicks pass through to whatever is underneath.
    mask: Region {}

    implicitWidth: 340
    implicitHeight: 64

    // PipeWire reports every device's levels as it connects; nothing shows until that settles.
    Timer {
        id: settled
        property bool done: false
        interval: 1500
        running: true
        onTriggered: done = true
    }
    Timer {
        id: linger
        interval: 260
    }
    Timer {
        id: hide
        interval: 1400
        onTriggered: osd.shown = false
    }

    PwObjectTracker {
        objects: [osd.sink, osd.source].filter(o => o)
    }
    Connections {
        target: osd.sink?.audio ?? null
        function onVolumeChanged() { osd.showVolume(); }
        function onMutedChanged() { osd.showVolume(); }
    }
    Connections {
        target: osd.source?.audio ?? null
        function onMutedChanged() { osd.showMic(); }
    }

    // `qs -c bar ipc call osd brightness`, which the brightness keys run after setting it.
    IpcHandler {
        target: "osd"

        function brightness(): void {
            readBrightness.running = true;
        }
    }
    Connections {
        target: OsdBus
        function onBrightness() { readBrightness.running = true; }
    }
    Process {
        id: readBrightness
        command: [Config.brightnessctl, "--machine-readable", "--class=backlight"]
        stdout: StdioCollector {
            onStreamFinished: {
                const fields = text.trim().split(",");
                if (fields.length >= 4) osd.show("brt", parseInt(fields[3]) / 100, false);
            }
        }
    }

    Item {
        id: body
        anchors.fill: parent
        opacity: osd.shown ? 1 : 0
        transform: Translate {
            y: osd.shown ? 0 : 12
            Behavior on y {
                NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
            }
        }

        Behavior on opacity {
            NumberAnimation { duration: 220 }
        }

        readonly property color tone: osd.muted ? Theme.muted : Theme.accent

        PlateShape {
            anchors.fill: parent
            cutTopLeft: 10
            cutBottomRight: 10
            fillOpacity: 0.95
            stripRight: true
            frameColor: body.tone
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 18
            spacing: 14

            Tag {
                text: osd.kind === "brt" ? "BRT" : osd.kind === "mic" ? "MIC" : "VOL"
                border.color: body.tone
            }

            // A wider version of the bar's rising gauge.
            Row {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 3
                height: 24

                Repeater {
                    model: osd.segments

                    Rectangle {
                        required property int index
                        readonly property bool lit: !osd.muted && index < Math.round(osd.level * osd.segments)

                        width: 7
                        height: 8 + index * (16 / (osd.segments - 1))
                        y: 24 - height
                        color: lit ? body.tone : Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.15)

                        Behavior on color {
                            ColorAnimation { duration: 80 }
                        }
                    }
                }
            }

            Label {
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: 52
                horizontalAlignment: Text.AlignRight
                text: osd.kind === "mic" ? (osd.muted ? "MUTE" : "LIVE")
                    : osd.muted ? "MUTE" : String(Math.round(osd.level * 100)).padStart(3, "0")
                color: osd.muted ? Theme.muted : Theme.fg
                font.pixelSize: 18
                font.bold: true
                font.letterSpacing: 1
            }
        }
    }
}
