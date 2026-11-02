{ ... }:

{
  perSystem = { pkgs, ... }: {
    devShells.default = pkgs.mkShell {
      packages = with pkgs; [
        # Nix formatting
        nixfmt

        # Nix linting and dead-code detection
        statix
        deadnix

        # Nix language server
        nixd

        # Sops-nix
        sops
        age
        ssh-to-age
      ];
    };
  };
}
