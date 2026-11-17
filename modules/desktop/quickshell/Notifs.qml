// The notification server, in place of mako: it owns org.freedesktop.Notifications, keeps the
// notifications the popups show, a short history, and do-not-disturb.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.Notifications

Singleton {
    id: root

    readonly property alias server: server
    // While on, only critical notifications pop up; the rest go straight to the history.
    property bool dnd: false
    // The last notifications, newest first, as plain data that outlives the notifications.
    property var history: []
    readonly property int historyLimit: 50

    function toggleDnd() {
        dnd = !dnd;
    }

    function dismissAll() {
        for (const n of Array.from(server.trackedNotifications.values)) n.dismiss();
    }

    function remember(n) {
        const entry = {
            app: n.appName,
            summary: n.summary,
            body: n.body,
            urgency: n.urgency,
            time: new Date()
        };
        history = [entry].concat(history).slice(0, historyLimit);
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
