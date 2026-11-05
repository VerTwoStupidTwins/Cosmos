{ config, lib, pkgs, ... }:

{
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      intel-media-driver
      vpl-gpu-rt
    ];
  };

  users.users.twins.extraGroups = [
    "render"
    "video"
  ];

  # Iris has encrypted, disk-backed resume swap. Preserve the session instead
  # of powering off when UPower reaches its critical battery threshold.
  services.upower.criticalPowerAction = lib.mkForce "Hibernate";

  environment.systemPackages = with pkgs; [
    pciutils
    libva-utils
    vulkan-tools
  ];
}
