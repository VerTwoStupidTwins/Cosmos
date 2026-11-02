{ inputs, self, ... }:

{
  flake.nixosConfigurations.thoth = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";

    modules = [
      # Shared NixOS configuration
      # Includes Home Manager integration,
      # the twins admin user, ZRAM, and boot settings.
      self.nixosModules.base
      self.nixosModules.sshServer
      ../../hosts/thoth/ssh.nix
      ../../hosts/thoth/git.nix
      ../../hosts/thoth/firmware.nix

      inputs.lanzaboote.nixosModules.lanzaboote
      self.nixosModules.secureBoot

      # Desktop environment
      self.nixosModules.niri
      self.nixosModules.greetd

      # Laptop functionality
      self.nixosModules.laptop

      # Chromebook-specific hardware
      self.nixosModules.chromebookAudio
      self.nixosModules.chromebookKeyboard

      # Disk layout
      inputs.disko.nixosModules.disko
      ../../hosts/thoth/disko.nix

      inputs.sops-nix.nixosModules.sops
      ../../hosts/thoth/ssh.nix

      # Thoth-specific configuration
      {
        networking.hostName = "thoth";

        # Hardware detection
        hardware.facter.reportPath = ../../hosts/thoth/facter.json;

        # Keep stateVersion specific to each machine.
        system.stateVersion = "26.05";

        # Desktop-specific Home Manager modules.
        # Shared twins configuration comes from base.
        home-manager.users.twins.imports = [
          self.homeModules.niri
          self.homeModules.laptop
        ];

        # Deploy-rs is available on Thoth only.
        home-manager.users.twins.home.packages = [
          inputs.deploy-rs.packages.x86_64-linux.default
        ];

        # Path to Thoth's Nix store signing key.
        # Only the path is declared, never the private key contents.
        home-manager.users.twins.home.sessionVariables.LOCAL_KEY =
          "/home/twins/.local/share/cosmos/deploy-signing.key";

      }
    ];
  };
}
