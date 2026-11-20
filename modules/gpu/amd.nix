# modules/gpu/amd.nix
#
# AMD's ROCm compute stack, on the kernel's amdgpu driver. A host imports nixos.gpu-amd and names its cards' LLVM
# targets:
#
#   gpu.amd.targets = [ "gfx1100" ];  # RX 7900 XT / XTX
#
# Modules that build ROCm software take config.gpu.amd.rocmPackages and compile for config.gpu.amd.targets.
{
  flake.modules.nixos.gpu-amd =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.gpu.amd;

      hwmonPowerLimit = pkgs.writeShellApplication {
        name = "hwmon-power-limit";
        text = builtins.readFile ./hwmon-power-limit.sh;
      };
    in
    {
      # Loaded once however many modules import it: the host, and the llama.cpp backend that needs this stack.
      key = "cosmos#gpu-amd";

      options.gpu.amd = {
        targets = lib.mkOption {
          type = lib.types.nonEmptyListOf lib.types.str;
          example = [ "gfx1100" ];
          description = ''
            LLVM targets of the host's AMD cards (gfx1100 for the RX 7900 series, gfx1030 for the RX 6800/6900).
            `rocminfo` lists them. ROCm software is compiled for these alone.
          '';
        };

        rocmPackages = lib.mkOption {
          type = lib.types.attrs;
          default = pkgs.rocmPackages;
          defaultText = lib.literalExpression "pkgs.rocmPackages";
          description = "The ROCm package set that ROCm software on this host is built with.";
        };

        powerLimits = lib.mkOption {
          type = lib.types.attrsOf lib.types.ints.positive;
          default = { };
          example = {
            "0000:1f:00.0" = 231;
          };
          description = ''
            Power limits in watts, by PCI address (`lspci -D`), which stays put across boots while card numbers
            don't. power1_cap_min and power1_cap_max under the card's hwmon directory show the range it accepts,
            in microwatts.
          '';
        };
      };

      config = {
        hardware.graphics.enable = true;
        # ROCm's runtime (HIP and OpenCL), where programs find it through /run/opengl-driver.
        hardware.amdgpu.opencl.enable = true;

        environment.systemPackages = [
          pkgs.nvtopPackages.full
          pkgs.amdgpu_top
          pkgs.pciutils
          pkgs.clinfo
          pkgs.vulkan-tools
          cfg.rocmPackages.rocminfo
          cfg.rocmPackages.rocm-smi
        ];

        # amdgpu and xe forget limits when they reload, so they're set at each boot.
        systemd.services.gpu-power-limits-amd = lib.mkIf (cfg.powerLimits != { }) {
          description = "Set the AMD cards' power limits";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = lib.escapeShellArgs (
              [ (lib.getExe hwmonPowerLimit) ]
              ++ lib.concatLists (
                lib.mapAttrsToList (address: watts: [
                  address
                  (toString watts)
                ]) cfg.powerLimits
              )
            );
          };
        };
      };
    };
}
