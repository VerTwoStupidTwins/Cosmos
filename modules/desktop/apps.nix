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
            obsidian
            telegram-desktop
            mpv
            pavucontrol
            # Game streaming from lugh's Wolf (modules/features/wolf.nix), over NetBird.
            moonlight-qt
          ];
        }
      )
    ];
  };
}
