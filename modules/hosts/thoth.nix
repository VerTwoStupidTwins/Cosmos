# Host definition: ThinkPad T490, encrypted Bcachefs root, Niri on first boot.
{ config, inputs, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  flake.modules.nixos.thoth = { lib, pkgs, ... }: {
    imports = [
      nixos.base
      nixos.workstation
      nixos."bcachefs-root"
      nixos."niri-desktop"
      inputs.disko.nixosModules.disko
      ../../disk-layouts/thoth.nix
    ];

    networking.hostName = "thoth";

    # REQUIRED: supply your real ThinkPad T490 report before evaluating.
    # Generate with nixos-facter or copy from your existing Cosmos repo.
    hardware.facter.reportPath = ../../hardware/thoth/facter.json;
    hardware.enableRedistributableFirmware = true;

    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    # NixOS 26.05 systemd initrd should wait for the decrypted mapper.
    # This is a single-device Bcachefs filesystem inside LUKS.
    fileSystems."/".device = lib.mkForce "/dev/mapper/cryptroot";

    # Persistent root: no ZFS, Preservation, or root snapshot rollback.
    users.mutableUsers = true;
    users.users.twins = {
      isNormalUser = true;
      createHome = true;
      extraGroups = [ "wheel" "networkmanager" ];
      shell = pkgs.fish;
    };

    system.stateVersion = "26.05";
  };

  flake.nixosConfigurations.thoth = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ nixos.thoth ];
  };
}
