{ inputs, self, ... }:

{
  flake.nixosConfigurations.iris = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";

    modules = [
      # Shared system and user configuration.
      self.nixosModules.base
      self.nixosModules.sshServer
      self.nixosModules.boot

      # Desktop environment.
      self.nixosModules.niri
      self.nixosModules.greetd

      # Generic laptop functionality. Chromebook-only modules are excluded.
      self.nixosModules.laptop

      # ASUS hardware discovered from the live installer.
      ../../hosts/iris/system.nix

      # Storage layout for the verified internal NVMe.
      inputs.disko.nixosModules.disko
      ../../hosts/iris/disko.nix

      # Host-key-backed secrets and SSH configuration.
      inputs.sops-nix.nixosModules.sops
      ../../hosts/iris/ssh.nix

      # Preserve the existing Git SSH-signing identity and trust policy.
      ../../hosts/thoth/git.nix

      {
        networking.hostName = "iris";
        hardware.facter.reportPath = ../../hosts/iris/facter.json;
        system.stateVersion = "26.05";

        home-manager.users.twins.imports = [
          self.homeModules.niri
          self.homeModules.laptop
        ];

        home-manager.users.twins.home.packages = [
          inputs.deploy-rs.packages.x86_64-linux.default
        ];

        home-manager.users.twins.home.sessionVariables.LOCAL_KEY =
          "/home/twins/.local/share/cosmos/deploy-signing.key";
      }
    ];
  };
}
