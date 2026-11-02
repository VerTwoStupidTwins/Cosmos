{ ... }:

{
  flake.homeModules.twinsDevelopment =
    { pkgs, ... }:
    {
      programs.direnv = {
        enable = true;
        enableFishIntegration = true;

        nix-direnv.enable = true;
      };

      # Shared command-line utilities
      home.packages = with pkgs; [
        ripgrep
        fd
        jq
      ];
    };
}
