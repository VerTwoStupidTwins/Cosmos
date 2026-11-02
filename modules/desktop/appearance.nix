
{ ... }:

{
  flake.homeModules.appearance =
    { pkgs, ... }:
    {
      programs.waybar = {
        enable = true;
        systemd.enable = true;

        settings.mainBar = {
          layer = "top";
          position = "top";
          height = 32;

          modules-left = [ "niri/workspaces" ];
          modules-center = [ "clock" ];
          modules-right = [
            "network"
            "pulseaudio"
            "battery"
            "tray"
          ];

          "niri/workspaces" = {
            format = "{index}";
          };

          clock.format = "{:%a %b %d  %H:%M}";

          network = {
            format-wifi = "WiFi {signalStrength}%";
            format-ethernet = "LAN";
            format-disconnected = "Offline";
            tooltip-format-wifi = "{essid}";
          };

          pulseaudio = {
            format = "VOL {volume}%";
            format-muted = "Muted";
            on-click = "pavucontrol";
          };

          battery = {
            format = "BAT {capacity}%";
            format-charging = "CHG {capacity}%";
            states = {
              warning = 25;
              critical = 10;
            };
          };

          tray.spacing = 8;
        };

        style = ''
          * {
            font-family: sans-serif;
            font-size: 13px;
            border: none;
          }

          window#waybar {
            background: #232136;
            color: #e0def4;
          }

          #workspaces button {
            color: #908caa;
            padding: 0 8px;
          }

          #workspaces button.active {
            color: #c4a7e7;
            background: #393552;
          }

          #clock, #network, #pulseaudio,
          #battery, #tray {
            padding: 0 10px;
          }

          #battery.warning {
            color: #f6c177;
          }

          #battery.critical {
            color: #eb6f92;
          }
        '';
      };

      services.mako = {
        enable = true;

        settings = {
          font = "sans-serif 11";
          background-color = "#232136";
          text-color = "#e0def4";
          border-color = "#c4a7e7";
          border-size = 2;
          border-radius = 8;
          default-timeout = 5000;
        };
      };

      services.wlsunset = {
        enable = true;
        sunrise = "07:00";
        sunset = "19:00";

        temperature = {
          day = 6500;
          night = 4000;
        };
      };

      services.awww.enable = true;

      home.packages = with pkgs; [
        pavucontrol
      ];
    };
}

