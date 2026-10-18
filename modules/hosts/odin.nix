# Ryzen 9 5900X / ASRock B550 Taichi: headless model-server foundation.
{ config, inputs, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  flake.modules.nixos.odin = { pkgs, ... }: {
    imports = [
      nixos.base
      nixos."bcachefs-root"
      nixos."model-tools"
      inputs.disko.nixosModules.disko
      ../../disk-layouts/odin.nix
    ];

    networking = {
      hostName = "odin";
      # Wired DHCP without the workstation/NetworkManager profile.
      useDHCP = true;
    };

    hardware = {
      # Collected on Odin with Cosmos's pinned nixos-facter, not another host.
      facter.reportPath = ../../hardware/odin/facter.json;
      enableRedistributableFirmware = true;
      cpu.amd.updateMicrocode = true;
      # Override Facter's hardware-based default; this headless host needs no BlueZ.
      bluetooth.enable = false;
    };
    boot.loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    services.fstrim.enable = true;
    services.smartd.enable = true;

    # Keep the server reachable; swap is not sized for hibernation.
    systemd.targets = {
      sleep.enable = false;
      suspend.enable = false;
      hibernate.enable = false;
      hybrid-sleep.enable = false;
      suspend-then-hibernate.enable = false;
    };

    users.mutableUsers = true;
    users.users.twins = {
      isNormalUser = true;
      createHome = true;
      extraGroups = [
        "wheel"
        "render"
      ];
      shell = pkgs.fish;
      # The private Cosmos Admin key stays in the client's 1Password agent.
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMWQySUPlG4H7prC8ftuSz52jQT8v7g7pzCPhB5b7MT"
      ];
      # Set the sudo/console password interactively before reboot, not in Git.
    };

    system.stateVersion = "26.05";
  };

  flake.nixosConfigurations.odin = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ nixos.odin ];
  };
}
