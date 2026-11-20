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
    in
    {
      options.gpu.intel = {
        computeRuntime = lib.mkOption {
          type = lib.types.package;
          default = pkgs.intel-compute-runtime;
          defaultText = lib.literalExpression "pkgs.intel-compute-runtime";
          description = "Intel's Level Zero and OpenCL driver for the cards.";
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
      };
    };
}
