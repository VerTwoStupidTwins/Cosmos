{ ... }:

{
  flake.nixosModules.kawiilGpu = { pkgs, ... }: {
    # AMD and Intel GPU firmware.
    hardware.enableRedistributableFirmware = true;

    hardware.graphics = {
      enable = true;

      # Required for 32-bit Vulkan applications,
      # including many Steam/Proton games.
      enable32Bit = true;

      extraPackages = with pkgs; [
        # Intel Arc Pro B50
        intel-media-driver
        vpl-gpu-rt
        intel-compute-runtime

        # AMD ROCm OpenCL runtime.
        # ROCm HIP will be configured separately.
        rocmPackages.clr.icd
      ];
    };

    # Allow the admin user to access GPU render devices.
    users.users.twins.extraGroups = [
      "render"
      "video"
    ];

    # Diagnostics.
    environment.systemPackages = with pkgs; [
      pciutils
      vulkan-tools
      clinfo
      libva-utils
    ];
  };
}
