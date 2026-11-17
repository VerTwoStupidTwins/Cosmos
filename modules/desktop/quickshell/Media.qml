// The media players over MPRIS, and which one the bar follows: the one picked last while it's
// around, otherwise the one playing, otherwise the first.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.Mpris

Singleton {
    id: root

    readonly property bool open: Panels.open === "media"
    // The identity of the player picked with cycle().
    property string picked: ""

    // playerctld only mirrors the other players; leave it out.
    readonly property var players: Array.from(Mpris.players.values).filter(p => !p.dbusName.includes("playerctld"))
    readonly property var active: players.find(p => p.identity === picked)
        ?? players.find(p => p.isPlaying)
        ?? players[0]
        ?? null

    function toggle() {
        Panels.toggle("media");
    }

    function cycle() {
        if (players.length < 2) return;
        const i = players.indexOf(active);
        picked = players[(i + 1) % players.length].identity;
    }

    function time(seconds) {
        if (!isFinite(seconds) || seconds < 0) return "--:--";
        const s = Math.floor(seconds);
        const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60);
        const mm = String(m).padStart(h > 0 ? 2 : 1, "0"), ss = String(s % 60).padStart(2, "0");
        return (h > 0 ? h + ":" : "") + mm + ":" + ss;
    }

    // MPRIS doesn't announce position as it plays; ask for it while something does.
    Timer {
        running: root.active?.isPlaying ?? false
        interval: 1000
        repeat: true
        onTriggered: root.active.positionChanged()
    }
}
