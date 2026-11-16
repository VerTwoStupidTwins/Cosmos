# modules/desktop/wayland.nix
# The pieces every Wayland session here shares: lock, idle, polkit agent, bar, launcher,
# notifications, terminal. Each compositor module imports this; `key` lets a host carry two
# compositors without the module system applying it twice. Colours come from theme.nix.
{
  flake.modules.nixos.wayland = {
    key = "cosmos/desktop/wayland";

    programs.hyprlock.enable = true; # registers the PAM service hyprlock needs
    services.upower.enable = true; # battery for the bar

    home-manager.sharedModules = [
      (
        { config, pkgs, ... }:
        let
          theme = "${config.xdg.stateHome}/theme";
          mono = config.stylix.fonts.monospace.name;
          sans = config.stylix.fonts.sansSerif.name;
        in
        {
          home.packages = with pkgs; [
            brightnessctl
            playerctl
            grim
            slurp
            wl-clipboard
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

          programs.wofi = {
            enable = true;
            settings = {
              show = "drun";
              prompt = "Search";
              allow_images = true;
              insensitive = true;
              no_actions = true;
              width = 600;
              height = 400;
              term = "kitty";
            };
            style = ''
              @import url("file://${theme}/colors.css");

              * { font-family: "${mono}"; font-size: 14px; }
              window { background-color: @base00; border: 2px solid @accent; border-radius: 10px; }
              #outer-box { padding: 6px; }
              #input { margin: 4px 4px 8px; padding: 6px 10px; border: none; border-radius: 6px;
                       background-color: @base01; color: @base05; }
              #inner-box, #scroll { background-color: transparent; }
              #entry { padding: 6px 10px; border-radius: 6px; }
              #entry:selected { background-color: @base02; }
              #text { color: @base05; }
              #entry:selected #text { color: @accent; }
            '';
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
                  readonly property string brightnessctl: "${pkgs.brightnessctl}/bin/brightnessctl"
                  readonly property string pavucontrol: "${pkgs.pavucontrol}/bin/pavucontrol"
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

          services.mako = {
            enable = true;
            settings = {
              font = "${sans} 11";
              border-size = 2;
              border-radius = 8;
              padding = "10";
              default-timeout = 5000;
            };
          };

          services.hyprpolkitagent.enable = true;

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
                lock_cmd = "pidof hyprlock || hyprlock";
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
