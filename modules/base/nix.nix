{
  flake.modules.nixos.base = {
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
