{ inputs, ... }:
{
  flake.modules.nixos.claude-code =
    { pkgs, ... }:
    {
      nixpkgs.overlays = [ inputs.claude-code.overlays.default ];

      nix.settings = {
        substituters = [ "https://claude-code.cachix.org" ];
        trusted-public-keys = [ "claude-code.cachix.org-1:YeXf2aNu7UTX8Vwrze0za1WEDS+4DuI2kVeWEE4fsRk=" ];
      };

      home-manager.sharedModules = [ { home.packages = [ pkgs.claude-code ]; } ];
    };
}
