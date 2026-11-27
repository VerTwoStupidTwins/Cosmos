{
  flake.modules.nixos.base = { pkgs, ... }: {
    environment.systemPackages = with pkgs; [
      git
      # The editor on every host, servers included; the desktop sets it up further (modules/desktop/editors.nix).
      helix
      curl
      htop
      lazygit
    ];

    # Git commits, sudoedit, crontab -e and the like open Helix rather than nano.
    environment.variables = {
      EDITOR = "hx";
      VISUAL = "hx";
    };
  };
}
