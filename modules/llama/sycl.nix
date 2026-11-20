# modules/llama/sycl.nix
#
# llama.cpp on Intel Arc cards through SYCL, which runs on Level Zero from Intel's compute runtime. On lugh, Vulkan
# slowed sharply on the Arc cards with long prompts: 40,000 tokens into a chat, the helper read 248 tokens a second
# and wrote 23, against 1,471 and 45 with SYCL.
{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  flake.modules.nixos.llama-sycl =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      runtime = config.gpu.intel.computeRuntime;
    in
    {
      imports = [
        nixos.llama
        nixos.gpu-intel
      ];

      llama.backends.sycl = {
        # The llama.cpp flake has no SYCL build, so this is nixpkgs' package on the same source, without the web UI
        # and without the tests, which need PyTorch.
        package = (pkgs.llama-cpp.override { syclSupport = true; }).overrideAttrs (old: {
          inherit (config.llama) src version;
          doCheck = false;
          nativeBuildInputs = builtins.filter (
            p: !(lib.hasPrefix "nodejs" (p.pname or p.name or "")) && (p.name or "") != "npm-config-hook"
          ) old.nativeBuildInputs;
          npmDeps = null;
          preConfigure = "";
          cmakeFlags = old.cmakeFlags ++ [
            "-DLLAMA_BUILD_WEBUI=OFF"
            # Half-precision maths in the SYCL kernels, as on lugh.
            "-DGGML_SYCL_F16=ON"
          ];
        });

        # SYCL finds Intel's driver through these rather than through /run/opengl-driver.
        env = {
          LD_LIBRARY_PATH = "${runtime}/lib";
          OCL_ICD_VENDORS = "${runtime}/etc/OpenCL/vendors";
        };

        devicePrefix = "SYCL";
        units = lib.optional (config.gpu.intel.powerLimits != { }) "gpu-power-limits-intel.service";
      };
    };
}
