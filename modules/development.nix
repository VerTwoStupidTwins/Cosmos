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
    apps.disko = {
      type = "app";
      program = "${inputs.disko.packages.${system}.disko}/bin/disko";
    };
  };
}
