# modules/gpu/intel.nix
#
# Intel's compute stack for Arc cards on the kernel's xe driver: the compute runtime gives Level Zero (which SYCL
# runs on) and OpenCL. A host imports nixos.gpu-intel; modules that run SYCL or OpenCL software find the runtime
# through /run/opengl-driver, or take config.gpu.intel.computeRuntime directly.
{
  flake.modules.nixos.gpu-intel =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.gpu.intel;

      hwmonPowerLimit = pkgs.writeShellApplication {
        name = "hwmon-power-limit";
        text = builtins.readFile ./hwmon-power-limit.sh;
      };
    in
    {
      options.gpu.intel = {
        computeRuntime = lib.mkOption {
          type = lib.types.package;
          default = pkgs.intel-compute-runtime;
          defaultText = lib.literalExpression "pkgs.intel-compute-runtime";
          description = "Intel's Level Zero and OpenCL driver for the cards.";
        };

        powerLimits = lib.mkOption {
          type = lib.types.attrsOf lib.types.ints.positive;
          default = { };
          example = {
            "0000:1b:00.0" = 60;
          };
          description = ''
            Power limits in watts, by PCI address (`lspci -D`), which stays put across boots while card numbers
            don't. Arc cards report their current cap but no range.
          '';
        };
      };

      config = {
        hardware.graphics = {
          enable = true;
          extraPackages = [
            cfg.computeRuntime
            # Video decoding and encoding.
            pkgs.intel-media-driver
            pkgs.vpl-gpu-rt
          ];
        };

        environment.systemPackages = [
          pkgs.nvtopPackages.full
          pkgs.intel-gpu-tools
          pkgs.pciutils
          pkgs.clinfo
          pkgs.vulkan-tools
        ];

        # amdgpu and xe forget limits when they reload, so they're set at each boot.
        systemd.services.gpu-power-limits-intel = lib.mkIf (cfg.powerLimits != { }) {
          description = "Set the Intel cards' power limits";
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
