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
