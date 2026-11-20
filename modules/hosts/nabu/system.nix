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
    ];

    gpu.nvidia.cudaCapabilities = [ "6.0" ]; # Tesla P100
    gpu.amd.targets = [ "gfx1100" ]; # RX 7900 XT

    nixpkgs.hostPlatform = "x86_64-linux";
    hardware.facter.reportPath = ./facter.json;
    system.stateVersion = "26.11";
  };
}
