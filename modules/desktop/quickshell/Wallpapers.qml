// Whether the wallpaper picker is open. `wallpaper` with no image opens it.
pragma Singleton

import Quickshell

Singleton {
    property bool open: false

    function toggle() {
        open = !open;
    }
}
