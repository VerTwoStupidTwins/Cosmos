# modules/desktop/niri.nix
# niri, a scrollable-tiling compositor. Lock, idle, bar and the rest come from the shared
# Wayland module; this holds niri itself and its config (niri.kdl, beside this file).
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

          # Written by hand; `niri validate` catches mistakes before they reach a session. The
          # wallpaper's colours come in through its optional include at runtime (theme.nix).
          xdg.configFile."niri/config.kdl".source =
            pkgs.runCommand "niri-config.kdl" { nativeBuildInputs = [ pkgs.niri ]; }
              ''
                niri validate -c ${./niri.kdl}
                cp ${./niri.kdl} "$out"
              '';
        }
      )
    ];
  };
}
