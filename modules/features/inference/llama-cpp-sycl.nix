# Intel SYCL prerequisites; each named instance selects its backend package.
{
  flake.modules.nixos."llama-cpp-sycl" =
    { pkgs, ... }:
    {

      cosmos.allowedUnfreePackages = [ "intel-oneapi-toolkit" ];
      hardware.graphics = {
        enable = true;
        extraPackages = [ pkgs.intel-compute-runtime ];
      };

    };
}
