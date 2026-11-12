# modules/desktop/apps.nix
{
  flake.modules.nixos.desktop = {
    home-manager.sharedModules = [
      (
        { pkgs, ... }:
        {
          programs.firefox.enable = true;

          home.packages = with pkgs; [
            discord
            telegram-desktop
            mpv
            pavucontrol
          ];
        }
      )
    ];
  };
}
