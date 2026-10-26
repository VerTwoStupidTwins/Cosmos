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
      nixos."honcho-local"
      nixos.openconcho
      nixos."onepassword-service-account"
      nixos."llama-cpp-sycl"
      nixos."llama-cpp-instances"
      inputs.disko.nixosModules.disko
      ../../disk-layouts/odin.nix
    ];

    # Initial build budget for the 24-thread server shared with inference.
    # Builders that honor cores may use six threads each, with two builds at once.
    nix.settings = {
      max-jobs = 2;
      cores = 6;
    };

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

    services = {
      openconcho = {
        listenAddress = "100.94.82.252";
        transportInterface = "enp4s0";
      };
      fstrim.enable = true;
      smartd.enable = true;
      llama-cpp-instances = {
        intel = {
          enable = false;
          # The B50 omits CSR-size tag 62; avoid the runtime's zero-sized
          # mid-thread buffer only in this package, not globally or on AMD.
          package = pkgs.callPackage ../../packages/llama-cpp-sycl/b50.nix {
            forceThreadGroupPreemption = true;
          };
          host = "127.0.0.1";
          port = 8080;
          model = null;
          renderDevice = "/dev/dri/by-path/pci-0000:10:00.0-render";
          settings.device = "SYCL0";
          allowJit = true;
          openFirewall = false;
        };
        amd = {
          enable = false;
          package = pkgs.llama-cpp-vulkan;
          host = "127.0.0.1";
          port = 8081;
          model = null;
          renderDevice = "/dev/dri/by-path/pci-0000:0d:00.0-render";
          settings.device = "Vulkan0";
          environment.VK_DRIVER_FILES = "${pkgs.mesa}/share/vulkan/icd.d/radeon_icd.x86_64.json";
          openFirewall = false;
        };
      };
    };

    # Keep the server reachable; swap is not sized for hibernation.
    systemd.targets = {
      sleep.enable = false;
      suspend.enable = false;
      hibernate.enable = false;
      hybrid-sleep.enable = false;
      suspend-then-hibernate.enable = false;
    };

    users.mutableUsers = true;
    users.users = {
      # Preserve the allocated Honcho UID; rootless OCI units require a stable ID.
      honcho.uid = 992;
      openconcho.uid = 991;
      twins = {
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
    };

    system.stateVersion = "26.05";
  };

  flake.nixosConfigurations.odin = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ nixos.odin ];
  };
}
