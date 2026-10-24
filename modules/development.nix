{ inputs, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    let
      operatorIdentity = pkgs.callPackage ../packages/sops-operator-identity.nix { };
    in
    {
      packages.cosmos-sops-identity = operatorIdentity;
      formatter = pkgs.nixfmt;
      devShells.default = pkgs.mkShell {
        packages = with pkgs; [
          git
          nixfmt
          nixd
          statix
          deadnix
          jq
          sops
          age
          ssh-to-age
        ];
        # Only the interactive editor uses 1Password; NixOS decryption uses host keys.
        SOPS_AGE_KEY_CMD = "${operatorIdentity}/bin/cosmos-sops-identity";
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
