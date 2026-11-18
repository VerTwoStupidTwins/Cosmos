// Removable drives, for the DRV readout and the drives plate: each USB or hot-plugged disk with its
// volumes, read from lsblk. udev events (a drive plugged or pulled) and findmnt's mount table
// polling (mounted or unmounted, by udiskie, Thunar or this plate) trigger a fresh read, so nothing
// is polled on a timer. udiskie still mounts drives as they arrive; the plate mounts, unmounts and
// ejects them with udisksctl, which asks polkit (and so the AUTH plate) when it needs a password.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    // [{ path, name, size, volumes: [{ path, device, label, fstype, size, used, mountpoint, locked }] }]
    property var drives: []
    // The device an action is running on ("" when none); one at a time.
    property string busy: ""
    readonly property int mounted: drives.reduce((n, d) => n + d.volumes.filter(v => v.mountpoint).length, 0)

    function size(bytes) {
        const units = ["B", "K", "M", "G", "T"];
        let i = 0;
        while (bytes >= 1000 && i < units.length - 1) {
            bytes /= 1000;
            i++;
        }
        return (bytes >= 100 || i === 0 ? Math.round(bytes) : bytes.toFixed(1)) + units[i];
    }

    function refresh() {
        if (!reader.running) reader.running = true;
        else again.restart();
    }

    function volumeOf(node) {
        // An unlocked LUKS partition carries its filesystem on the crypt device beneath it.
        const inner = node.fstype === "crypto_LUKS" ? (node.children ?? []).find(c => c.type === "crypt") : null;
        const fs = inner ?? node;
        return {
            path: fs.path,
            // The partition itself, which differs from path while a LUKS volume is unlocked.
            device: node.path,
            label: fs.label || node.label || node.name,
            fstype: fs.fstype ?? "",
            size: fs.size ?? node.size,
            used: fs.fsused ?? 0,
            mountpoint: fs.mountpoint ?? "",
            locked: node.fstype === "crypto_LUKS" && !inner
        };
    }

    function parse(json) {
        const devices = JSON.parse(json).blockdevices ?? [];
        return devices
            .filter(d => d.type === "disk" && (d.rm || d.hotplug) && d.tran !== null && d.size > 0)
            .map(d => {
                const parts = (d.children ?? []).filter(c => c.type === "part" && c.fstype);
                const volumes = parts.length > 0 ? parts.map(volumeOf) : d.fstype ? [volumeOf(d)] : [];
                const name = [d.vendor, d.model].filter(s => s).join(" ").trim();
                return { path: d.path, name: name || volumes[0]?.label || d.name, size: d.size, volumes: volumes };
            });
    }

    // Runs one udisksctl step (or several, for eject); a failure becomes a notification.
    function run(device, script, env) {
        if (busy !== "") return;
        busy = device;
        action.environment = Object.assign({ UDISKSCTL: Config.udisksctl, NOTIFY: Config.notifySend, DEV: device }, env ?? {});
        action.command = [Config.bash, "-c", script];
        action.running = true;
    }
    function mount(volume) {
        run(volume.path, 'out=$("$UDISKSCTL" mount -b "$DEV" 2>&1) || "$NOTIFY" -a Drives -u critical "Couldn\'t mount $DEV" "$out"');
    }
    function unmount(volume) {
        run(volume.path, 'out=$("$UDISKSCTL" unmount -b "$DEV" 2>&1) || "$NOTIFY" -a Drives -u critical "Couldn\'t unmount $DEV" "$out"');
    }
    function open(volume) {
        Quickshell.execDetached([Config.xdgOpen, volume.mountpoint]);
    }
    // Unmounts every volume, locks any unlocked LUKS one, then powers the drive off so it's safe to pull.
    function eject(drive) {
        run(drive.path, `
            for v in $VOLUMES; do
                out=$("$UDISKSCTL" unmount -b "$v" 2>&1) || { "$NOTIFY" -a Drives -u critical "Couldn't eject $NAME" "$out"; exit 1; }
            done
            for v in $UNLOCKED; do
                out=$("$UDISKSCTL" lock -b "$v" 2>&1) || { "$NOTIFY" -a Drives -u critical "Couldn't eject $NAME" "$out"; exit 1; }
            done
            if out=$("$UDISKSCTL" power-off -b "$DEV" 2>&1); then
                "$NOTIFY" -a Drives -i drive-removable-media "$NAME" "Safe to remove."
            else
                "$NOTIFY" -a Drives -u critical "Couldn't power off $NAME" "$out"
            fi`, {
            NAME: drive.name,
            VOLUMES: drive.volumes.filter(v => v.mountpoint).map(v => v.path).join(" "),
            UNLOCKED: drive.volumes.filter(v => v.device !== v.path).map(v => v.device).join(" ")
        });
    }

    Process {
        id: reader
        command: [Config.lsblk, "-J", "-b", "-o", "PATH,NAME,TYPE,RM,HOTPLUG,TRAN,VENDOR,MODEL,LABEL,FSTYPE,SIZE,FSUSED,MOUNTPOINT"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.drives = root.parse(text);
                } catch (e) {
                    console.warn("Drives: couldn't read lsblk:", e);
                }
            }
        }
    }

    Process {
        id: action
        onExited: {
            root.busy = "";
            root.refresh();
        }
    }

    // Events come in bursts (a drive's disk, then each partition); read once they settle.
    Timer {
        id: again
        interval: 300
        onTriggered: root.refresh()
    }

    // Long-running watchers; each line they print is a change. Restarted if they ever stop.
    Process {
        id: udev
        command: [Config.udevadm, "monitor", "--udev", "--subsystem-match=block"]
        running: true
        stdout: SplitParser {
            onRead: again.restart()
        }
        onExited: restart.start()
    }
    Process {
        id: mounts
        command: [Config.findmnt, "--poll", "--noheadings", "--output", "ACTION"]
        running: true
        stdout: SplitParser {
            onRead: again.restart()
        }
        onExited: restart.start()
    }
    Timer {
        id: restart
        interval: 5000
        onTriggered: {
            udev.running = true;
            mounts.running = true;
        }
    }

    Component.onCompleted: refresh()
}
