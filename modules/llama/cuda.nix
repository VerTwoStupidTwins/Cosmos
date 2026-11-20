# modules/llama/cuda.nix
#
# llama.cpp on NVIDIA cards through CUDA, built with the host's CUDA release for its cards' compute capabilities
# only (gpu.nvidia.cudaCapabilities).
{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  flake.modules.nixos.llama-cuda =
    { config, ... }:
    {
      imports = [
        nixos.llama
        nixos.gpu-nvidia
      ];

      llama.backends.cuda = {
        package =
          (config.llama.packages.llama-cpp.override {
            useCuda = true;
            inherit (config.gpu.nvidia) cudaPackages;
            useWebUi = false;
          }).overrideAttrs
            { webui = null; };

        # CUDA numbers cards fastest first by default, so identical cards can trade numbers between boots. In
        # PCI order, CUDA0 is always the same slot.
        env.CUDA_DEVICE_ORDER = "PCI_BUS_ID";

        devicePrefix = "CUDA";
      };
    };
}
