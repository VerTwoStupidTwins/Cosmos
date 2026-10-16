# Dell OptiPlex 3060 Mini Tower: dedicated, headless Frigate NVR.
{ config, inputs, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  flake.modules.nixos.argus = { pkgs, ... }: {
    imports = [
      nixos.base
      nixos."frigate-nvr"
      nixos."nvidia-headless"
      inputs.disko.nixosModules.disko
      ../../disk-layouts/argus.nix
    ];

    networking = {
      hostName = "argus";
      # Wired DHCP, without pulling in the workstation/NetworkManager profile.
      useDHCP = true;
    };

    # Real report collected on the Dell using Cosmos's pinned nixos-facter.
    hardware = {
      facter.reportPath = ../../hardware/argus/facter.json;
      enableRedistributableFirmware = true;
      cpu.intel.updateMicrocode = true;
    };
    boot = {
      loader = {
        systemd-boot.enable = true;
        efi.canTouchEfiVariables = true;
      };
    };

    services.fstrim.enable = true;
    services.smartd.enable = true;

    # An always-on recorder must not suspend/hibernate through logind.
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
      extraGroups = [ "wheel" ];
      shell = pkgs.fish;
      # Personal Cosmos admin identity; the private key remains in 1Password.
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMWQySUPlG4H7prC8ftuSz52jQT8v7g7pzCPhB5b7MT"
      ];
      # Set a password locally for sudo; never put credentials in Git.
    };

    system.stateVersion = "26.05";
  };

  flake.nixosConfigurations.argus = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ nixos.argus ];
  };
}
