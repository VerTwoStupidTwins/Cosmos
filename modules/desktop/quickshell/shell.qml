// The bar's entry point: a top and a bottom bar on every screen, the top one with its own
// command station.
import Quickshell
import Quickshell.Io

ShellRoot {
    // `qs -c bar ipc call station toggle`, for a keybind.
    IpcHandler {
        target: "station"

        function toggle(): void {
            Station.toggle();
        }
    }

    // `qs -c bar ipc call lab toggle` for the homelab page, Mod+B.
    IpcHandler {
        target: "lab"

        function toggle(): void {
            Homelab.toggle();
        }
    }

    // Named apart from the IPC function below, which would otherwise shadow it.
    Lock {
        id: locker
    }

    // `qs -c bar ipc call lock lock`, which hypridle runs for `loginctl lock-session`.
    IpcHandler {
        target: "lock"

        function lock(): void {
            locker.lock();
        }
    }

    // The application launcher, on the first screen.
    LauncherPanel {
        screen: Quickshell.screens[0]
    }

    // `qs -c bar ipc call launcher toggle`, for a keybind.
    IpcHandler {
        target: "launcher"

        function toggle(): void {
            Launcher.toggle();
        }
    }

    // The wallpaper picker, on the first screen.
    WallpaperPanel {
        screen: Quickshell.screens[0]
    }

    // `qs -c bar ipc call wallpaper toggle`, which `wallpaper` with no image runs.
    IpcHandler {
        target: "wallpaper"

        function toggle(): void {
            Wallpapers.toggle();
        }
    }

    // The power menu, on the first screen; the battery readout and Mod+Shift+E open it.
    PowerMenu {
        screen: Quickshell.screens[0]
        locker: locker
    }

    // `qs -c bar ipc call power toggle`, for a keybind.
    IpcHandler {
        target: "power"

        function toggle(): void {
            Power.toggle();
        }
    }

    // `qs -c bar ipc call media toggle` for the media plate, and play-pause / next / previous
    // for the player the bar follows.
    IpcHandler {
        target: "media"

        function toggle(): void {
            Media.toggle();
        }
        function playPause(): void {
            Media.active?.togglePlaying();
        }
        function next(): void {
            Media.active?.next();
        }
        function previous(): void {
            Media.active?.previous();
        }
    }

    // `qs -c bar ipc call tablet rotation|keyboard` lock rotation or toggle the on-screen keyboard
    // in tablet mode; `toggle` pretends the laptop was folded (or unfolded), for testing.
    IpcHandler {
        target: "tablet"

        function rotation(): void {
            Tablet.toggleRotationLock();
        }
        function keyboard(): void {
            Tablet.toggleKeyboard();
        }
        function toggle(): void {
            Tablet.toggle();
        }
    }

    // The pen menu, on the first screen; it comes up as the stylus leaves its garage.
    PenMenu {
        screen: Quickshell.screens[0]
    }

    // `qs -c bar ipc call pen menu` brings the pen menu up (or down) by hand; `note` starts a new
    // drawing in the Notes vault, as the menu's NOTE does.
    IpcHandler {
        target: "pen"

        function menu(): void {
            Pen.toggleMenu();
        }
        function note(): void {
            Pen.note();
        }
    }

    // `qs -c bar ipc call panels audio|network|bluetooth` for the bottom bar's VOL, COM and BT plates.
    IpcHandler {
        target: "panels"

        function audio(): void {
            Panels.toggle("audio");
        }
        function network(): void {
            Panels.toggle("network");
        }
        function bluetooth(): void {
            Panels.toggle("bluetooth");
        }
    }

    // `qs -c bar ipc call drives toggle` for the drives plate.
    IpcHandler {
        target: "drives"

        function toggle(): void {
            Panels.toggle("drives");
        }
    }

    // Password prompts for polkit (udisksctl, systemctl, pkexec…), on the first screen.
    PolkitPanel {
        screen: Quickshell.screens[0]
    }

    // `qs -c bar ipc call caffeine toggle`, to keep the screen awake.
    IpcHandler {
        target: "caffeine"

        function toggle(): void {
            Caffeine.toggle();
        }
    }

    // `qs -c bar ipc call recorder region|screen` starts a recording (or stops the one running),
    // `stop` stops it.
    IpcHandler {
        target: "recorder"

        function region(): void {
            Recorder.toggle("region");
        }
        function screen(): void {
            Recorder.toggle("screen");
        }
        function stop(): void {
            Recorder.stop();
        }
    }

    // Clipboard history, on the first screen.
    ClipboardPanel {
        screen: Quickshell.screens[0]
    }

    // `qs -c bar ipc call clipboard toggle`, for Mod+Ctrl+V.
    IpcHandler {
        target: "clipboard"

        function toggle(): void {
            Panels.clipboard = !Panels.clipboard;
        }
    }

    // What to do while a recording's region is being picked.
    RecorderHint {
        screen: Quickshell.screens[0]
    }

    // Touch strips on the built-in screen's edges while folded into a tablet.
    EdgeSwipes {
        screen: Quickshell.screens.find(s => s.name === Tablet.output) ?? Quickshell.screens[0]
    }

    // The keyboard backlight: Alt + the brightness keys, dark when idle or folded.
    KbdLight {}

    // `qs -c bar ipc call nightlight toggle`.
    IpcHandler {
        target: "nightlight"

        function toggle(): void {
            NightLight.toggle();
        }
    }

    // A notification for each screenshot niri takes; clicking it opens satty.
    Screenshots {}

    // Notifications when the battery runs low.
    BatteryWatch {}

    // Volume, mic and brightness as they change, on the first screen.
    Osd {
        screen: Quickshell.screens[0]
    }

    // The notification log, on the first screen.
    NotificationLog {
        screen: Quickshell.screens[0]
    }

    // Notifications pop up on the first screen.
    NotificationPopups {
        screen: Quickshell.screens[0]
    }

    // `qs -c bar ipc call notifications dnd`, `dismiss` to clear the popups, `log` for the log.
    IpcHandler {
        target: "notifications"

        function dnd(): void {
            Notifs.toggleDnd();
        }
        function dismiss(): void {
            Notifs.dismissAll();
        }
        function log(): void {
            Notifs.toggleLog();
        }
    }

    Variants {
        model: Quickshell.screens

        Bar {
            required property var modelData
            screen: modelData
        }
    }

    Variants {
        model: Quickshell.screens

        BottomBar {
            required property var modelData
            screen: modelData
        }
    }
}
