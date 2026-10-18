# Intel SYCL prerequisites; each named instance selects its backend package.
{
  flake.modules.nixos."llama-cpp-sycl" =
    {
      lib,
      pkgs,
      ...
    }:
    {
      nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "intel-oneapi-toolkit";
      hardware.graphics = {
        enable = true;
        extraPackages = [ pkgs.intel-compute-runtime ];
      };

    };
}
