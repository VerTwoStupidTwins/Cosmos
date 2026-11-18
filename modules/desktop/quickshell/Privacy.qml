// What is capturing right now, from PipeWire's links: apps recording from a microphone, using a
// camera, or capturing the screen (a video source with no device behind it, as niri's screencasts
// are). Apps that open a camera or the sound card directly, bypassing PipeWire, don't show.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.Pipewire

Singleton {
    id: root

    readonly property var groups: Array.from(Pipewire.linkGroups.values)

    readonly property var mic: users(g => kind(g.source) === "mic")
    readonly property var camera: users(g => kind(g.source) === "camera")
    readonly property var screen: users(g => kind(g.source) === "screen")
    readonly property bool active: mic.length + camera.length + screen.length > 0

    // From the node's type flags and name, which are there for every node (its properties only
    // fill in once something binds it). Cameras are named by their API: v4l2_… or libcamera_….
    function kind(node) {
        if (!node || node.isStream) return "";
        const audioSource = PwNodeType.Audio | PwNodeType.Source;
        const videoSource = PwNodeType.Video | PwNodeType.Source;
        if ((node.type & audioSource) === audioSource && !(node.type & PwNodeType.Sink)) return "mic";
        if ((node.type & videoSource) === videoSource) return /^(v4l2|libcamera)/.test(node.name) ? "camera" : "screen";
        return "";
    }

    function name(node) {
        const p = node?.properties ?? {};
        return p["application.name"] || node?.description || node?.nickname || node?.name || "unknown";
    }

    // The distinct apps on the receiving end of the matching links.
    function users(match) {
        return Array.from(new Set(groups.filter(g => g.target && match(g)).map(g => name(g.target))));
    }
}
