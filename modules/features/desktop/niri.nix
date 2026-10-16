# Compositor-specific settings; shared desktop features live in base-desktop.
{
  flake.modules.nixos."niri-desktop" = { pkgs, ... }: {
    programs.niri.enable = true;
    environment.systemPackages = [ pkgs.xwayland-satellite ];
  };
}
