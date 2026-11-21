{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  # The infrastructure server: an Intel Core Ultra 7 265K desktop with 32 GB of RAM. It's meant for the services
  # that should stay up whatever happens to the other servers (Matrix first), Nix builds, and the Minecraft and Foundry VTT servers.
  hosts.kobold =
    { pkgs, ... }:
    {
      imports = [
        nixos.systemd-boot
        nixos.server
        nixos.builder
        nixos.monitor
        nixos.matrix
      ];

      monitor.allowStation = true;

      # Its first boots, on 7.3.3 with i915 and xe both loaded for the iGPU, corrupted memory, though memtest86+
      # found nothing all day. So: the LTS kernel rather than the base's latest, and only xe for the iGPU
      # (Arrow Lake-S, 8086:7d67), which is the driver it's meant to use later anyway; i915 is told to leave it.
      boot.kernelPackages = pkgs.linuxPackages;
      boot.kernelParams = [
        "i915.force_probe=!7d67"
        "xe.force_probe=7d67"
        # The crashes keep hitting filesystem data while plain memory tests pass, and the NVMe's PCIe 5.0
        # link logs receiver errors, so a device writing where it shouldn't is a suspect. In strict mode
        # the IOMMU unmaps DMA buffers at once, so a late or stray write becomes a logged DMAR fault
        # instead of silently landing in reused memory. It costs a little I/O speed.
        "iommu.strict=1"
      ];

      nixpkgs.hostPlatform = "x86_64-linux";
      hardware.facter.reportPath = ./facter.json;
      system.stateVersion = "26.11";
    };
}
