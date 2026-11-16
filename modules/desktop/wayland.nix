# modules/desktop/wayland.nix
# The pieces every Wayland session here shares: lock, idle, polkit agent, bar, launcher,
# notifications, terminal. Each compositor module imports this; `key` lets a host carry two
# compositors without the module system applying it twice.
{
  flake.modules.nixos.wayland = {
    key = "cosmos/desktop/wayland";

    programs.hyprlock.enable = true; # registers the PAM service hyprlock needs

    home-manager.sharedModules = [
      (
        { pkgs, ... }:
        {
          home.packages = with pkgs; [
            brightnessctl
            playerctl
            grim
            slurp
            wl-clipboard
          ];

          programs.kitty.enable = true;
          programs.wofi.enable = true;
          programs.waybar.enable = true;
          services.mako.enable = true;

          services.hyprpolkitagent.enable = true;

          programs.hyprlock = {
            enable = true;
            settings = {
              background = [ { color = "rgb(1e1e2e)"; } ];
              input-field = [
                {
                  size = "300, 50";
                  position = "0, 0";
                  halign = "center";
                  valign = "center";
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
