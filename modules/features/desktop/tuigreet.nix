# Keyboard-driven login and session selection for Wayland workstations.
{
  flake.modules.nixos."tuigreet-login" =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      services.greetd = {
        enable = true;
        useTextGreeter = true;
        settings.default_session = {
          user = "greeter";
          command = lib.escapeShellArgs [
            "${pkgs.tuigreet}/bin/tuigreet"
            "--remember"
            "--remember-user-session"
            "--sessions"
            "${config.services.displayManager.sessionData.desktops}/share/wayland-sessions"
            "--xsessions"
            "${config.services.displayManager.sessionData.desktops}/share/xsessions"
          ];
        };
      };
    };
}
