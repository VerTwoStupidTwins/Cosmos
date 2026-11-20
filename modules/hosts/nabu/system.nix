{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  # The LLM server, taking over from lugh: an ASUS WS C422 SAGE/10G with a Xeon W-2145 and 128 GB of ECC RAM.
  # Its GPUs come from three vendors: two Tesla P100s (16 GB HBM2 each), lugh's Radeon RX 7900 XT (20 GB) and
  # lugh's Arc Pro B50 (16 GB). Named for the Mesopotamian god of scribes and wisdom.
  hosts.nabu = {
    imports = [
      nixos.systemd-boot
      nixos.server
      nixos.gpu-nvidia
      nixos.gpu-amd
      nixos.gpu-intel
      nixos.llama-cuda
      nixos.llama-rocm
      nixos.llama-sycl
      nixos.llama-vulkan
    ];

    gpu.nvidia.cudaCapabilities = [ "6.0" ]; # Tesla P100
    gpu.amd.targets = [ "gfx1100" ]; # RX 7900 XT

    # The 1200 W supply also feeds a 140 W Xeon. Stock, the cards alone would draw about 830 W, with the 7900 XT
    # spiking above that; these keep them near 690 W. Inference is mostly limited by memory bandwidth, so the
    # P100s lose little at 200 W.
    gpu.nvidia.powerLimits = {
      "0000:20:00.0" = 200; # P100, of 125-250 W
      "0000:68:00.0" = 200; # P100
    };
    gpu.amd.powerLimits."0000:1f:00.0" = 231; # RX 7900 XT, its minimum (stock 257 W)
    gpu.intel.powerLimits."0000:1b:00.0" = 60; # Arc Pro B50 (stock 70 W)

    nixpkgs.hostPlatform = "x86_64-linux";
    hardware.facter.reportPath = ./facter.json;
    system.stateVersion = "26.11";
  };
}
