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
            # The agent behind Obsidian's Copilot plugin (its own download is a generic Linux binary): Copilot's
            # OpenCode setting points at this one, with nabu's models as a custom provider.
            opencode
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
