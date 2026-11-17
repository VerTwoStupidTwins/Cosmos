// The bar's entry point: one bar on every screen, each with its own command station.
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

    // Volume, mic and brightness as they change, on the first screen.
    Osd {
        screen: Quickshell.screens[0]
    }

    // Notifications pop up on the first screen.
    NotificationPopups {
        screen: Quickshell.screens[0]
    }

    // `qs -c bar ipc call notifications dnd`, and `dismiss` to clear the popups.
    IpcHandler {
        target: "notifications"

        function dnd(): void {
            Notifs.toggleDnd();
        }
        function dismiss(): void {
            Notifs.dismissAll();
        }
    }

    Variants {
        model: Quickshell.screens

        Bar {
            required property var modelData
            screen: modelData
        }
    }
}
