// The notification server, in place of mako: it owns org.freedesktop.Notifications, keeps the
// notifications the popups show, a history the log panel lists, and do-not-disturb.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications

Singleton {
    id: root

    readonly property alias server: server
    // While on, only critical notifications pop up; the rest go straight to the history.
    property bool dnd: false
    // Whether the log panel is open.
    property bool logOpen: false
    // The last notifications, newest first, as plain data that outlives them. Kept in Quickshell's
    // state directory, so it survives the bar restarting, as it does on every switch.
    property var history: []
    // How many arrived since the log was last opened.
    property int unread: 0
    readonly property int historyLimit: 50

    function toggleDnd() {
        dnd = !dnd;
    }

    function toggleLog() {
        logOpen = !logOpen;
        if (logOpen) unread = 0;
    }

    function dismissAll() {
        for (const n of Array.from(server.trackedNotifications.values)) n.dismiss();
    }

    function forget(id) {
        history = history.filter(e => e.id !== id);
        save();
    }

    function clearHistory() {
        history = [];
        unread = 0;
        save();
    }

    function remember(n) {
        const entry = {
            id: Date.now() + "-" + n.id,
            app: n.appName,
            icon: n.appIcon,
            summary: n.summary,
            body: n.body,
            urgency: n.urgency,
            time: Date.now()
        };
        history = [entry].concat(history).slice(0, historyLimit);
        if (!logOpen) unread++;
        save();
    }

    function save() {
        store.setText(JSON.stringify({ history: history, unread: unread }));
    }

    FileView {
        id: store
        path: Quickshell.statePath("notifications.json")
        printErrors: false
        onLoaded: {
            try {
                const data = JSON.parse(text());
                root.history = data.history ?? [];
                root.unread = data.unread ?? 0;
            } catch (e) {}
        }
    }

    NotificationServer {
        id: server

        actionsSupported: true
        bodyMarkupSupported: true
        bodyHyperlinksSupported: true
        imageSupported: true
        persistenceSupported: true
        keepOnReload: true

        onNotification: n => {
            root.remember(n);
            // Untracked notifications are dropped, which is how do-not-disturb silences them.
            if (root.dnd && n.urgency !== NotificationUrgency.Critical) return;
            n.tracked = true;
        }
    }
}
