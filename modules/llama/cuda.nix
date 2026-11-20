# modules/llama/cuda.nix
#
# llama.cpp on NVIDIA cards through CUDA, built with the host's CUDA release for its cards' compute capabilities
# only (gpu.nvidia.cudaCapabilities). A host can build it from a fork tuned for its cards (llama.cuda.src) while
# the other backends stay on upstream.
{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  flake.modules.nixos.llama-cuda =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.llama.cuda;
      scope = pkgs.callPackage "${cfg.src}/.devops/nix/scope.nix" { llamaVersion = cfg.version; };
    in
    {
      imports = [
        nixos.llama
        nixos.gpu-nvidia
      ];

      options.llama.cuda = {
        src = lib.mkOption {
          type = lib.types.path;
          default = config.llama.src;
          defaultText = lib.literalExpression "config.llama.src";
          description = "The llama.cpp source the CUDA backend builds from.";
        };

        version = lib.mkOption {
          type = lib.types.str;
          default = config.llama.version;
          defaultText = lib.literalExpression "config.llama.version";
          description = "The version the CUDA backend's package carries.";
        };

        cmakeFlags = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Extra CMake flags for the CUDA build.";
        };

        env = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = "Extra environment for the CUDA backend's programs, such as a fork's runtime switches.";
        };
      };

      config.llama.backends.cuda = {
        package =
          (scope.llama-cpp.override {
            useCuda = true;
            inherit (config.gpu.nvidia) cudaPackages;
            useWebUi = false;
          }).overrideAttrs
            (old: {
              webui = null;
              cmakeFlags = old.cmakeFlags ++ cfg.cmakeFlags;
            });

        # CUDA numbers cards fastest first by default, so identical cards can trade numbers between boots. In
        # PCI order, CUDA0 is always the same slot.
        env = {
          CUDA_DEVICE_ORDER = "PCI_BUS_ID";
        }
        // cfg.env;

        devicePrefix = "CUDA";

        # The driver loads late in boot, and the cards appear once nvidia-persistenced holds them.
        units = [
          "nvidia-persistenced.service"
        ]
        ++ lib.optional (config.gpu.nvidia.powerLimits != { }) "gpu-power-limits-nvidia.service";
      };
    };
}
