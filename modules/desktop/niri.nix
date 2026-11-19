# modules/desktop/niri.nix
# niri, a scrollable-tiling compositor. Lock, idle, bar and the rest come from the shared
# Wayland module; this holds niri itself and its config.
{ config, ... }:
{
  flake.modules.nixos.niri = {
    imports = [ config.flake.modules.nixos.wayland ];

    programs.niri.enable = true;

    # The niri module turns on gnome-keyring, which brings gcr-ssh-agent; that agent sets
    # SSH_AUTH_SOCK in the systemd user environment and would shadow 1Password's agent.
    services.gnome.gcr-ssh-agent.enable = false;

    home-manager.sharedModules = [
      (
        { pkgs, ... }:
        {
          # niri runs X11 apps through xwayland-satellite when it is on PATH.
          home.packages = [ pkgs.xwayland-satellite ];

          # niri's own default config, patched only where it names software this system
          # doesn't use. --replace-fail breaks the build if upstream rewords a line, and
          # `niri validate` catches anything else before it reaches a session.
          xdg.configFile."niri/config.kdl".source =
            pkgs.runCommand "niri-config.kdl" { nativeBuildInputs = [ pkgs.niri ]; }
              ''
                cp ${pkgs.niri.src}/resources/default-config.kdl config.kdl
                substituteInPlace config.kdl \
                  --replace-fail \
                    'Mod+T hotkey-overlay-title="Open a Terminal: alacritty" { spawn "alacritty"; }' \
                    'Mod+Return hotkey-overlay-title="Open a Terminal: kitty" { spawn "kitty"; }' \
                  --replace-fail \
                    'Mod+D hotkey-overlay-title="Run an Application: fuzzel" { spawn "fuzzel"; }' \
                    'Mod+Space hotkey-overlay-title="Run an Application" { spawn "qs" "-c" "bar" "ipc" "call" "launcher" "toggle"; }
                    Mod+Shift+W hotkey-overlay-title="Change the Wallpaper" { spawn "wallpaper"; }
                    Mod+S hotkey-overlay-title="Toggle the Command Station" { spawn "qs" "-c" "bar" "ipc" "call" "station" "toggle"; }
                    Mod+B hotkey-overlay-title="Toggle the Homelab" { spawn "qs" "-c" "bar" "ipc" "call" "lab" "toggle"; }
                    Mod+N hotkey-overlay-title="Toggle Do Not Disturb" { spawn "qs" "-c" "bar" "ipc" "call" "notifications" "dnd"; }
                    Mod+Shift+N hotkey-overlay-title="Show the Notification Log" { spawn "qs" "-c" "bar" "ipc" "call" "notifications" "log"; }
                    Mod+Shift+S hotkey-overlay-title="Screenshot a Region" { screenshot; }
                    Mod+Ctrl+S hotkey-overlay-title="Screenshot the Window" { screenshot-window; }
                    Mod+Ctrl+Shift+S hotkey-overlay-title="Screenshot the Screen" { screenshot-screen; }
                    Mod+Ctrl+V hotkey-overlay-title="Clipboard History" { spawn "qs" "-c" "bar" "ipc" "call" "clipboard" "toggle"; }
                    Mod+Alt+S hotkey-overlay-title="Record a Region (again to stop)" { spawn "qs" "-c" "bar" "ipc" "call" "recorder" "region"; }
                    Mod+Alt+Shift+S hotkey-overlay-title="Record the Screen (again to stop)" { spawn "qs" "-c" "bar" "ipc" "call" "recorder" "screen"; }' \
                  --replace-fail \
                    'XF86MonBrightnessUp allow-when-locked=true { spawn "brightnessctl" "--class=backlight" "set" "+10%"; }' \
                    'XF86MonBrightnessUp allow-when-locked=true { spawn-sh "brightnessctl --class=backlight set +10% && qs -c bar ipc call osd brightness"; }' \
                  --replace-fail \
                    'XF86MonBrightnessDown allow-when-locked=true { spawn "brightnessctl" "--class=backlight" "set" "10%-"; }' \
                    'XF86MonBrightnessDown allow-when-locked=true { spawn-sh "brightnessctl --class=backlight set 10%- && qs -c bar ipc call osd brightness"; }
                    Alt+XF86MonBrightnessUp allow-when-locked=true { spawn "qs" "-c" "bar" "ipc" "call" "kbdlight" "up"; }
                    Alt+XF86MonBrightnessDown allow-when-locked=true { spawn "qs" "-c" "bar" "ipc" "call" "kbdlight" "down"; }' \
                  --replace-fail \
                    'Mod+Shift+E { quit; }' \
                    'Mod+Shift+E hotkey-overlay-title="Power Menu" { spawn "qs" "-c" "bar" "ipc" "call" "power" "toggle"; }' \
                  --replace-fail \
                    'Super+Alt+L hotkey-overlay-title="Lock the Screen: swaylock" { spawn "swaylock"; }' \
                    'Super+Alt+L hotkey-overlay-title="Lock the Screen" { spawn "loginctl" "lock-session"; }' \
                  --replace-fail \
                    '// Example: block out two password managers from screen capture.' \
                    '// Small tools and stand-alone dialogs float instead of taking a whole column.
                window-rule {
                    match app-id=r#"^org\.pulseaudio\.pavucontrol$"#
                    match app-id=r#"^xdg-desktop-portal-gtk$"#
                    match app-id=r#"^com\.gabm\.satty$"#
                    match app-id=r#"^org\.gnome\.FileRoller$"#
                    match app-id=r#"^thunar$"# title=r#"^(File Operation Progress|Confirm to replace files|Rename ".*")$"#
                    match app-id=r#"^com\.onepassword\.OnePassword$"# title=r#"^Quick Access"#
                    open-floating true
                }
                window-rule {
                    match app-id=r#"^org\.pulseaudio\.pavucontrol$"#
                    default-column-width { fixed 720; }
                    default-window-height { fixed 520; }
                }
                // File pickers from the portal, roomy enough to browse in.
                window-rule {
                    match app-id=r#"^xdg-desktop-portal-gtk$"#
                    default-column-width { proportion 0.6; }
                    default-window-height { proportion 0.7; }
                }

                // 1Password never shows up in screen shares or recordings (screenshots still see it).
                window-rule {
                    match app-id=r#"^com\.onepassword\.OnePassword$"#
                    block-out-from "screencast"
                }

                // Example: block out two password managers from screen capture.' \
                  --replace-fail \
                    'spawn-at-startup "waybar"' \
                    '// The bar is Quickshell, started as a systemd user service.
                spawn-at-startup "1password" "--silent"
                spawn-at-startup "wallpaper" "--restore"'
                niri validate -c config.kdl

                # The wallpaper's colours, written at runtime by `wallpaper` (theme.nix). Appended
                # after validation because the file doesn't exist at build time, and last so it
                # overrides the stock colours.
                printf '\ninclude "~/.local/state/theme/niri.kdl"\n' >> config.kdl
                cp config.kdl "$out"
              '';
        }
      )
    ];
  };
}
