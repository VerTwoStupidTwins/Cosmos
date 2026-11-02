{ inputs, self, ... }:

{
  flake.nixosConfigurations.kawiil = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";

    modules = [
      # Shared system configuration
      self.nixosModules.base
      self.nixosModules.sshServer
      self.nixosModules.boot

      # Secrets
      inputs.sops-nix.nixosModules.sops
      ../../hosts/kawiil/ssh.nix

      inputs.disko.nixosModules.disko
      ../../hosts/kawiil/disko.nix

      # Kawiil-specific configuration
      {
        nix.settings.extra-trusted-public-keys = [
          "cosmos-deploy-1:N6ZWI51z7ixRUnSIJsgutoimWOA+Vkup1Ut2P0WBWxY="
        ];

        networking = {
          hostName = "kawiil";

          # Initial wired network management via DHCP.
          # We can make this declarative after inspecting the NICs.
          networkmanager.enable = true;
        };

        # Hardware detection
        hardware.facter.reportPath = ../../hosts/kawiil/facter.json;

        # This is a fresh NixOS installation.
        system.stateVersion = "26.05";
      }
    ];
  };
}
