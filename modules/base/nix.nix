{ inputs, ... }:
{
  flake.modules.nixos.base = {
    # Records the commit each build came from; a build with uncommitted changes gets the commit before them, marked dirty.
    system.configurationRevision = inputs.self.rev or inputs.self.dirtyRev or null;

    nix = {
      settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
      };
      optimise.automatic = true;
    };

    nixpkgs.config.allowUnfree = true;

    programs.nh = {
      enable = true;
      flake = "/Cosmos";
      clean.enable = true;
      clean.extraArgs = "--keep-since 7d --keep 5";
    };
  };
}
