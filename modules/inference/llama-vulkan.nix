{ inputs, ... }:

{
  flake.nixosModules.llamaVulkan =
    { pkgs, ... }:
    let
      llamaCpp = inputs.llama-cpp.packages.${pkgs.stdenv.hostPlatform.system}.vulkan;
    in
    {
      services.llama-cpp.package = llamaCpp;

      environment.systemPackages = [
        llamaCpp
        pkgs.python314Packages.huggingface-hub
      ];
    };
}
