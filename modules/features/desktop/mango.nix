# Optional Mango session; shared locking is supplied by laptop-sleep.
{
  flake.modules.nixos."mango-desktop" = { config, pkgs, ... }: {
    programs.mango.enable = true;

    systemd = {
      # Mango imports its Wayland environment and starts this shipped target.
      packages = [
        config.programs.mango.package
        pkgs.waybar
        pkgs.mako
      ];

      user.services = {
        # Start the packaged bar with Mango; it stops with the graphical session.
        waybar = {
          wantedBy = [ "mango-session.target" ];
          unitConfig.ConditionEnvironment = "WAYLAND_DISPLAY";
        };

        # Start notifications with Mango, not only on D-Bus demand.
        mako = {
          wantedBy = [ "mango-session.target" ];
          unitConfig.ConditionEnvironment = "WAYLAND_DISPLAY";
        };

        # Run the wallpaper daemon only for the Mango session.
        awww = {
          description = "awww wallpaper daemon";
          wantedBy = [ "mango-session.target" ];
          partOf = [ "mango-session.target" ];
          after = [ "graphical-session.target" ];
          unitConfig.ConditionEnvironment = "WAYLAND_DISPLAY";
          serviceConfig = {
            Type = "simple";
            ExecStart = "${pkgs.awww}/bin/awww-daemon";
            Restart = "on-failure";
            RestartSec = 1;
          };
        };
      };
    };

    # The package installs defaults in the store, but Mango falls back to /etc.
    # Keep user configs untouched and use the existing workstation applications.
    environment.etc."mango/config.conf".text = ''
      bind=SUPER,Return,spawn,${pkgs.alacritty}/bin/alacritty
      bind=SUPER,d,spawn,${pkgs.fuzzel}/bin/fuzzel
      bind=SUPER,Escape,spawn,${pkgs.swaylock-effects}/bin/swaylock -f
      bind=SUPER+SHIFT,q,quit
      bind=SUPER,q,killclient
      bind=SUPER,r,reload_config
      bind=SUPER,Tab,focusstack,next
      bind=SUPER,n,switch_layout
      bind=ALT,Left,focusdir,left
      bind=ALT,Right,focusdir,right
      bind=ALT,Up,focusdir,up
      bind=ALT,Down,focusdir,down
    '';
  };
}
