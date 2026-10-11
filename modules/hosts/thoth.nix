# Host definition: ThinkPad T490, encrypted Bcachefs root, Niri on first boot.
{ config, inputs, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  flake.modules.nixos.thoth = { pkgs, ... }: {
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

    # Root and persistent swap are LVs inside cryptroot.
    # Explicitly identify the hibernation resume LV for systemd initrd.
    boot = {
      loader = {
        systemd-boot.enable = true;
        efi.canTouchEfiVariables = true;
      };
      initrd.services.lvm.enable = true;
      resumeDevice = "/dev/vg_thoth/lv_swap";
    };
    powerManagement.enable = true;

    # Persistent root: no ZFS, Preservation, or root snapshot rollback.
    users.mutableUsers = true;
    users.users.twins = {
      isNormalUser = true;
      createHome = true;
      extraGroups = [
        "wheel"
        "networkmanager"
      ];
      shell = pkgs.fish;
    };

    system.stateVersion = "26.05";
  };

  flake.nixosConfigurations.thoth = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ nixos.thoth ];
  };
}
