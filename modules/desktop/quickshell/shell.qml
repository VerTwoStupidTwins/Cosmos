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

    Variants {
        model: Quickshell.screens

        Bar {
            required property var modelData
            screen: modelData
        }
    }
}
