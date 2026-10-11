# Thoth package and service manifest

All packages are declared through `environment.systemPackages` or
`fonts.packages`; the Niri compositor and Fish are enabled through their
NixOS `programs` options. This list reflects the packages in the Nix files.

| Group | Included |
| --- | --- |
| Desktop | Niri, SDDM, Waybar, Wofi, Fuzzel, Mako |
| Terminals | Alacritty, Kitty |
| Lock / idle | swaylock-effects, swayidle |
| Wallpaper | awww |
| Wayland utilities | xwayland-satellite, SwayOSD, wev, wlr-randr, LXQt Polkit |
| Screenshots | grim, slurp, swappy |
| Clipboard | wl-clipboard, wl-clip-persist, Clipse |
| File management | Thunar, thunar-archive-plugin, thunar-volman, Tumbler, GVfs, Udiskie, file-roller, Yazi |
| Audio / media | PipeWire, pavucontrol, Helvum, FFmpeg, MPV |
| Network and Bluetooth UI | networkmanagerapplet (includes `nm-connection-editor`), Blueman |
| Shell / terminal development | Fish, Starship, Zellij, fzf, ripgrep, fd, zoxide, bat, eza, bottom, jq, yq, lazygit, Neovim |
| Desktop applications | Firefox, Emacs, LibreOffice, Evince, imv, ImageMagick, GNOME Keyring |
| System utilities | brightnessctl, playerctl, powertop, TLP, Flatpak, Podman, Buildah, Skopeo, Git, curl, nano, vim |
| Font | Monoid Nerd Font |

## Deliberately not included

- Convertible-only packages and services: `wvkbd`, `iio-niri`,
  `iio-sensor-proxy`, `tablet-mode.target`, auto-rotation, and tablet OSK.
- Competing clipboard history managers: `cliphist`, `clipman`, `copyq`,
  `clipcat`. We kept **Clipse** as the history manager; `wl-clipboard` provides
  `wl-copy` and `wl-paste`; `wl-clip-persist` is for persistence.
- Rofi, qpwgraph or the old plain swaylock package, per earlier selections.
- Proprietary apps such as 1Password and VS Code, pending an explicit choice
  of licensing settings or distribution method.

## Default Niri shortcuts (unmodified upstream configuration)

`Super+T` opens Alacritty; `Super+D` launches Fuzzel. Both are included so
these shortcuts work without custom keybindings. Wofi and Kitty are installed
for switching to your preferred bindings once you decide how to configure Niri.

Only the required compositor/display-manager and core services are enabled.
The clipboard manager, wallpaper daemon, Waybar customization and Polkit agent
are not given custom autostart rules by this repository. The default Niri
configuration might launch components such as Waybar itself.

Installing the `tlp`, `flatpak`, `podman` and `gnome-keyring` packages does not
by itself enable all their associated services. Those choices are deferred.
