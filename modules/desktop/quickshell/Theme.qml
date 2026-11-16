// Colours from the current wallpaper. `wallpaper` (theme.nix) rewrites the file and the bar
// picks it up straight away; the defaults only show until the first write.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    readonly property color bg: colors.base00
    readonly property color surface: colors.base01
    readonly property color muted: colors.base03
    readonly property color dim: colors.base04
    readonly property color fg: colors.base05
    readonly property color urgent: colors.base08
    readonly property color warn: colors.base0a
    readonly property color good: colors.base0b
    readonly property color accent: colors.accent

    readonly property string font: Config.font
    readonly property int fontSize: 13

    FileView {
        path: Config.themeFile
        watchChanges: true
        onFileChanged: reload()

        adapter: JsonAdapter {
            id: colors
            property string base00: "#1e1e2e"
            property string base01: "#181825"
            property string base03: "#45475a"
            property string base04: "#a6adc8"
            property string base05: "#cdd6f4"
            property string base08: "#f38ba8"
            property string base0a: "#f9e2af"
            property string base0b: "#a6e3a1"
            property string accent: "#89b4fa"
        }
    }
}
