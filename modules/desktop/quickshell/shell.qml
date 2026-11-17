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

    Variants {
        model: Quickshell.screens

        Bar {
            required property var modelData
            screen: modelData
        }
    }
}
