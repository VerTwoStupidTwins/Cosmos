# modules/desktop/wayland.nix
# The pieces every Wayland session here shares: lock, idle, polkit agent, bar, launcher,
# notifications, terminal. Each compositor module imports this; `key` lets a host carry two
# compositors without the module system applying it twice. Colours come from theme.nix.
{
  flake.modules.nixos.wayland = {
    key = "cosmos/desktop/wayland";

    programs.hyprlock.enable = true; # registers the PAM service hyprlock needs
    # The Quickshell lock screen checks passwords through this one (Lock.qml).
    security.pam.services.quickshell = { };
    services.upower.enable = true; # battery for the bar

    home-manager.sharedModules = [
      # nixpkgs' NetBird module renames netbird-ui to netbird-ui-<client> throughout its desktop
      # file, the store path in Icon= included, so the icon points at a path that doesn't exist.
      # This copy, which takes precedence, has the real one.
      (
        { osConfig, lib, ... }:
        let
          netbird = osConfig.services.netbird;
        in
        # The wrapper follows the global ui.enable (on with a graphical session), not the client's.
        lib.mkIf (netbird.clients ? wt0 && netbird.ui.enable) {
          xdg.dataFile."applications/netbird-wt0.desktop".text = lib.generators.toINI { } {
            "Desktop Entry" = {
              Name = "NetBird @ netbird-wt0";
              Comment = "NetBird desktop client";
              Exec = "env WEBKIT_DISABLE_DMABUF_RENDERER=1 netbird-ui-wt0";
              Icon = "${netbird.ui.package}/share/icons/hicolor/256x256/apps/netbird.png";
              Type = "Application";
              Terminal = false;
              Categories = "Utility;";
              Keywords = "netbird;";
              StartupWMClass = "org.wails.netbird";
            };
          };
        }
      )
      (
        {
          config,
          osConfig,
          lib,
          pkgs,
          ...
        }:
        let
          theme = "${config.xdg.stateHome}/theme";
          mono = config.stylix.fonts.monospace.name;
          # Set by the convertible module (2-in-1s).
          convertible = osConfig.hardware.sensor.iio.enable;

          # The command station's readings, in sections the bar parses (Station.qml). It runs every
          # two seconds, so it reads files with bash builtins rather than starting a process per
          # file, and only the sensors the station shows: some (cros_ec, iwlwifi) take tens of
          # milliseconds to answer.
          stationProbe = pkgs.writeShellScript "station-probe" ''
            PATH=${
              lib.makeBinPath [
                pkgs.coreutils
                pkgs.iproute2
              ]
            }
            value() { local v; read -r v < "$1" 2>/dev/null && echo "$v"; }

            echo @stat
            while read -r l; do [[ $l == cpu* ]] && echo "$l"; done < /proc/stat
            echo @mem
            while read -r l; do [[ $l == @(MemTotal|MemAvailable|SwapTotal|SwapFree):* ]] && echo "$l"; done < /proc/meminfo
            echo @load; value /proc/loadavg
            echo @uptime; value /proc/uptime
            echo @freq
            for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do value "$f"; done
            echo @temp
            for h in /sys/class/hwmon/hwmon*; do
              name=$(value "$h/name")
              case $name in
                k10temp | coretemp | amdgpu | nvme) ;;
                *) continue ;;
              esac
              for t in "$h"/temp*_input; do
                [ -f "$t" ] || continue
                label=$(value "''${t%_input}_label") || label=temp
                case $label in Tctl | Package* | edge | Composite) echo "$name|$label|$(value "$t")" ;; esac
              done
            done
            echo @gpu
            for d in /sys/class/drm/card[0-9]*/device; do
              [ -f "$d/gpu_busy_percent" ] || continue
              echo "$(value "$d/gpu_busy_percent") $(value "$d/mem_info_vram_used") $(value "$d/mem_info_vram_total")"
              break
            done
            echo @bat
            for b in /sys/class/power_supply/BAT*; do
              [ -d "$b" ] || continue
              for f in capacity status power_now energy_now energy_full current_now charge_now charge_full voltage_now; do
                [ -f "$b/$f" ] && echo "$f $(value "$b/$f")"
              done
              break
            done
            echo @route; ip -4 route show default
            echo @addr; ip -4 -br addr
            echo @net
            { read -r; read -r; while IFS= read -r l; do echo "$l"; done; } < /proc/net/dev
            echo @df; df -B1 --output=target,size,used / /boot 2>/dev/null | { read -r; while read -r l; do echo "$l"; done; }
          '';

          # What the station's header shows and only changes with a reboot or switch.
          stationInfo = pkgs.writeShellScript "station-info" ''
            read -r host < /proc/sys/kernel/hostname; echo "$host"
            ${pkgs.coreutils}/bin/uname -r
            # The file has no trailing newline, so it's read rather than printed.
            read -r version < /run/current-system/nixos-version; echo "$version"
            /run/current-system/sw/bin/nixos-version --configuration-revision 2>/dev/null || echo
          '';
          sans = config.stylix.fonts.sansSerif.name;
        in
        {
          home.packages = with pkgs; [
            brightnessctl
            playerctl
            grim
            slurp
            wl-clipboard
            libnotify # notify-send, for scripts to reach the bar's notifications
          ];

          programs.kitty = {
            enable = true;
            settings = {
              window_padding_width = 8;
              confirm_os_window_close = 0;
              enable_audio_bell = false;
              scrollback_lines = 10000;
              cursor_shape = "beam";
              tab_bar_edge = "top";
              tab_bar_style = "powerline";
            };
          };

          # The bar: Quickshell, from ./quickshell plus a generated Config.qml with the paths and
          # font it needs. Colours come from the theme's quickshell.json (theme.nix).
          programs.quickshell = {
            enable = true;
            configs.bar = pkgs.runCommand "quickshell-bar" { } ''
              mkdir $out
              cp ${./quickshell}/*.qml $out/
              cat > $out/Config.qml <<'QML'
              pragma Singleton
              import Quickshell

              Singleton {
                  readonly property string themeFile: "${theme}/quickshell.json"
                  readonly property string font: "${mono}"
                  readonly property string sans: "${sans}"
                  readonly property string brightnessctl: "${pkgs.brightnessctl}/bin/brightnessctl"
                  readonly property string pavucontrol: "${pkgs.pavucontrol}/bin/pavucontrol"
                  readonly property string stationProbe: "${stationProbe}"
                  readonly property string wallpaper: "${theme}/wallpaper"
                  readonly property string coreutils: "${pkgs.coreutils}/bin"
                  readonly property string terminal: "${config.programs.kitty.package}/bin/kitty"
                  readonly property string systemdRun: "${pkgs.systemd}/bin/systemd-run"
                  readonly property string notifySend: "${pkgs.libnotify}/bin/notify-send"
                  readonly property string wlCopy: "${pkgs.wl-clipboard}/bin/wl-copy"
                  readonly property string xdgOpen: "${pkgs.xdg-utils}/bin/xdg-open"
                  readonly property string satty: "${pkgs.satty}/bin/satty"
                  readonly property string bash: "${pkgs.bash}/bin/bash"
                  readonly property string slurp: "${pkgs.slurp}/bin/slurp"
                  readonly property string wfRecorder: "${pkgs.wf-recorder}/bin/wf-recorder"
                  readonly property string gammastep: "${pkgs.gammastep}/bin/gammastep"
                  readonly property string ffmpeg: "${pkgs.ffmpeg}/bin/ffmpeg"
                  readonly property string lsblk: "${lib.getExe' pkgs.util-linux "lsblk"}"
                  readonly property string findmnt: "${lib.getExe' pkgs.util-linux "findmnt"}"
                  readonly property string udevadm: "${lib.getExe' pkgs.systemd "udevadm"}"
                  readonly property string udisksctl: "${lib.getExe' pkgs.udisks "udisksctl"}"
                  readonly property string cliphist: "${config.services.cliphist.package}/bin/cliphist"
                  readonly property string stationInfo: "${stationInfo}"
                  // Empty where the bar can't reach the homelab (Homelab.qml).
                  readonly property string homelab: "${lib.optionalString (osConfig.monitor.labCommand != null) "${osConfig.monitor.labCommand}"}"
                  readonly property string wallpaperCommand: "${config.cosmos.wallpaper}/bin/wallpaper"
                  readonly property string wallpaperCurrent: "${theme}/current"
                  readonly property string wallpaperDir: "${config.cosmos.wallpaperDir}"
                  readonly property string wallpaperLibrary: "${config.xdg.dataHome}/wallpapers"
                  // 2-in-1s (the convertible module): tablet mode, rotation and the on-screen
                  // keyboard (Tablet.qml). Empty elsewhere.
                  readonly property bool convertible: ${lib.boolToString convertible}
                  readonly property string evtest: "${lib.optionalString convertible (lib.getExe pkgs.evtest)}"
                  readonly property string iioNiri: "${lib.optionalString convertible (lib.getExe pkgs.iio-niri)}"
                  readonly property string wvkbd: "${lib.optionalString convertible (lib.getExe' pkgs.wvkbd "wvkbd-mobintl")}"
                  // The pen menu's note app (Pen.qml).
                  readonly property string rnote: "${lib.optionalString convertible (lib.getExe pkgs.rnote)}"
                  readonly property string grim: "${lib.getExe pkgs.grim}"
              }
              QML
            '';
            activeConfig = "bar";
            systemd.enable = true;
          };
          systemd.user.services.quickshell.Unit = {
            # Stop with the session, and restart when the bar's files change.
            PartOf = [ config.wayland.systemd.target ];
            X-Restart-Triggers = [ "${config.programs.quickshell.configs.bar}" ];
          };

          # Notifications are the Quickshell bar's (Notifs.qml), not mako's.

          # Clipboard history: every copy, text and images, for the bar's picker (ClipboardPanel.qml).
          services.cliphist = {
            enable = true;
            allowImages = true;
          };

          # The polkit agent is the Quickshell bar's (PolkitPanel.qml), not hyprpolkitagent's.

          # $base00…$base0f come from the theme's hyprlock.conf, sourced first.
          programs.hyprlock = {
            enable = true;
            settings = {
              background = [
                {
                  path = "${theme}/wallpaper";
                  color = "$base00";
                  blur_passes = 2;
                  brightness = 0.7;
                }
              ];
              label = [
                {
                  text = "$TIME";
                  color = "$base05";
                  font_family = mono;
                  font_size = 64;
                  position = "0, 120";
                  halign = "center";
                  valign = "center";
                }
              ];
              input-field = [
                {
                  size = "300, 50";
                  position = "0, 0";
                  halign = "center";
                  valign = "center";
                  outer_color = "$accent";
                  inner_color = "$base01";
                  font_color = "$base05";
                  check_color = "$base0a";
                  fail_color = "$base08";
                }
              ];
            };
          };

          services.hypridle = {
            enable = true;
            settings = {
              general = {
                # The Quickshell lock screen, or hyprlock when the bar isn't running to show it.
                lock_cmd = "${config.programs.quickshell.package}/bin/qs -c bar ipc call lock lock || pidof hyprlock || hyprlock";
                before_sleep_cmd = "loginctl lock-session";
              };
              listener = [
                {
                  timeout = 300;
                  on-timeout = "loginctl lock-session";
                }
                {
                  timeout = 900;
                  on-timeout = "systemctl suspend-then-hibernate";
                }
              ];
            };
          };
        }
      )
    ];
  };
}
