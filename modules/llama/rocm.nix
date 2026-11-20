# modules/llama/rocm.nix
#
# llama.cpp on AMD cards through ROCm (HIP), built for the host's cards' targets only (gpu.amd.targets).
{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  flake.modules.nixos.llama-rocm =
    { config, lib, ... }:
    {
      imports = [
        nixos.llama
        nixos.gpu-amd
      ];

      llama.backends.rocm = {
        package =
          (config.llama.packages.llama-cpp.override {
            useRocm = true;
            inherit (config.gpu.amd) rocmPackages;
            rocmGpuTargets = lib.concatStringsSep ";" config.gpu.amd.targets;
            useWebUi = false;
          }).overrideAttrs
            { webui = null; };

        devicePrefix = "ROCm";
      };
    };
}
