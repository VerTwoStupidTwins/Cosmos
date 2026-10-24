{ config, inputs, ... }:
{
  flake.modules.nixos."sops-secrets" = {
    imports = [ inputs.sops-nix.nixosModules.sops ];
    sops = {
      defaultSopsFile = ../../../secrets.yaml;
      defaultSopsFormat = "yaml";
      age = {
        sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
        keyFile = null;
        generateKey = false;
      };
      gnupg.sshKeyPaths = [ ];
    };
  };

  perSystem = { pkgs, ... }: {
    checks.sops-bootstrap = import ../../../tests/sops-bootstrap.nix {
      inherit pkgs;
      operatorIdentity = config.flake.packages.${pkgs.stdenv.hostPlatform.system}.cosmos-sops-identity;
      odin = config.flake.nixosConfigurations.odin.config;
      thoth = config.flake.nixosConfigurations.thoth.config;
    };
  };
}
