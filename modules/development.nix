{ inputs, ... }:
{
  perSystem = { pkgs, system, ... }: {
    formatter = pkgs.nixfmt;
    devShells.default = pkgs.mkShell {
      packages = with pkgs; [
        git
        nixfmt
        nixd
        statix
        deadnix
        jq
      ];
    };

    # Run exactly the Disko revision pinned in Cosmos/flake.lock.
    apps = {
      disko = {
        type = "app";
        program = "${inputs.disko.packages.${system}.disko}/bin/disko";
      };
      # Use the installer packaged by Cosmos's already-pinned nixpkgs.
      nixos-anywhere = {
        type = "app";
        program = "${pkgs.nixos-anywhere}/bin/nixos-anywhere";
        meta.description = "Install a reviewed Cosmos host over SSH";
      };
    };
  };
}
