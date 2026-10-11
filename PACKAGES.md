# Thoth package and service manifest

This inventory reflects the NixOS modules currently committed in Cosmos. Installed packages, enabled system services, and session-started applications are different things: **a package being present does not mean it starts automatically**.

## Installed packages

| Group | Included |
| --- | --- |
| Desktop | Niri (enabled via NixOS), SDDM (enabled via NixOS), Waybar, Wofi, Fuzzel, Mako |
| Terminals | Alacritty, Kitty |
| Lock / idle | swaylock-effects, swayidle |
| Wallpaper | awww |
| Wayland | xwayland-satellite, SwayOSD, wev, wlr-randr, LXQt Polkit |
| Screenshots | grim, slurp, swappy |
| Clipboard | wl-clipboard, wl-clip-persist, Clipse |
| File management | Thunar, thunar-archive-plugin, thunar-volman, Tumbler, GVfs, Udiskie, file-roller, Yazi |
| Audio / media | PipeWire, pavucontrol, **Crosspipe**, FFmpeg, MPV |
| Network and Bluetooth UI | networkmanagerapplet, Blueman |
| CLI | Fish, Starship, Zellij, fzf, ripgrep, fd, zoxide, bat, eza, bottom, jq, yq, lazygit, Neovim |
| Desktop applications | Firefox, Emacs, LibreOffice, Evince, imv, ImageMagick, GNOME Keyring, **1Password GUI** |
| Utilities | brightnessctl, playerctl, powertop, TLP, Flatpak, Podman, Buildah, Skopeo, Git, curl, nano |
| Font | Monoid Nerd Font |

The NixOS 1Password module enables the 1Password desktop integration; its unfree-package allowance is set in `modules/features/security/onepassword.nix`. This repository does **not** currently install Helvum or VS Code.

## Services and configuration currently enabled

- **Niri / SDDM:** `programs.niri.enable` and `services.displayManager.sddm.enable`, with SDDM Wayland enabled.
- **Sound:** PipeWire ALSA/PulseAudio, RTKit.
- **Desktop integration:** Polkit, GVfs, UDisks2, Tumbler, Bluetooth, NetworkManager.
- **LXQt Polkit agent:** `systemd.user.services.lxqt-policykit-agent`, wanted by `graphical-session.target`. Verify it is actually running after graphical login.
- **1Password SSH:** 1Password desktop integration enabled; OpenSSH client uses `~/.1password/agent.sock` and its built-in `ssh-agent` is disabled. The app must have its SSH agent enabled and running.
- **NetBird:** named client `wt0`, interface `wt0`, UDP port `58120`, automatic start, hardened mode, and NetBird firewall options enabled.
- **DNS and remote access:** systemd-resolved, OpenSSH server, and the NixOS firewall. SSH is currently opened by `services.openssh.openFirewall = true`, not limited to NetBird.

## Not yet configured by Cosmos

- Custom Niri `config.kdl`, shortcuts, Waybar styling, or wallpaper selection.
- Explicit systemd user units for Waybar, Mako, swayidle, awww, and clipboard utilities.
- Home Manager (flake input exists but is not activated).
- Automatic startup for every optional package: installing TLP, Flatpak, Podman, GNOME Keyring, or similar packages does not imply all related services are enabled.
- Convertible/tablet-specific tools: wvkbd, iio-niri, tablet-mode controls, and rotation utilities.
- Alternative clipboard history managers such as cliphist or copyq; Clipse is the selected tool.
- Helvum, qpwgraph, Rofi, or the original non-effects swaylock.

## Verification

```fish
cd /Cosmos
nix eval --json '.#nixosConfigurations.thoth.config.programs.niri.enable'
nix eval --json '.#nixosConfigurations.thoth.config.programs._1password-gui.enable'
nix eval --raw '.#nixosConfigurations.thoth.config.services.netbird.clients.wt0.interface'
systemctl --user status lxqt-policykit-agent.service
```

Niri's upstream defaults commonly use `Super+T` for Alacritty and `Super+D` for Fuzzel; Cosmos does not yet declare these bindings itself.
