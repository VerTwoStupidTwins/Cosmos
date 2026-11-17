// The lock screen: a Wayland session lock with a cockpit surface on every screen, unlocked through
// PAM (the `quickshell` service, see wayland.nix).
//
// If Quickshell dies while locked, the compositor keeps the screen locked and blank. That's what
// keeps the session safe, but it would also lock you out, so a marker file in XDG_RUNTIME_DIR
// records that the lock is up, and the next Quickshell start (systemd restarts it) locks again
// straight away, so there's a password field to type into.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pam

Scope {
    id: root

    readonly property string marker: Quickshell.env("XDG_RUNTIME_DIR") + "/quickshell-locked"

    // Shared by every screen's field, so typing on one screen shows on all.
    property string text: ""
    property bool busy: false
    property bool failed: false
    property string message: ""
    property int attempts: 0

    function lock() {
        if (sessionLock.locked) return;
        text = "";
        failed = false;
        message = "";
        Quickshell.execDetached([Config.coreutils + "/touch", marker]);
        sessionLock.locked = true;
    }

    function submit() {
        if (busy || text.length === 0) return;
        busy = true;
        failed = false;
        message = "";
        if (!pam.start()) {
            busy = false;
            message = "AUTH SERVICE UNAVAILABLE";
        }
    }

    function unlock() {
        Quickshell.execDetached([Config.coreutils + "/rm", "-f", marker]);
        sessionLock.locked = false;
        text = "";
        attempts = 0;
        message = "";
    }

    WlSessionLock {
        id: sessionLock

        LockSurface {
            lock: root
        }
    }

    PamContext {
        id: pam
        config: "quickshell"

        onPamMessage: {
            if (responseRequired) respond(root.text);
            else if (messageIsError) root.message = message.toUpperCase();
        }
        onCompleted: result => {
            root.busy = false;
            if (result === PamResult.Success) {
                root.unlock();
            } else {
                root.attempts += 1;
                root.failed = true;
                root.message = "ACCESS DENIED";
                root.text = "";
            }
        }
        onError: error => {
            root.busy = false;
            root.failed = true;
            root.message = "AUTH ERROR";
            root.text = "";
        }
    }

    // Lock again if the last Quickshell went away while locked.
    FileView {
        path: root.marker
        printErrors: false
        onLoaded: root.lock()
    }
}
