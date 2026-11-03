{ inputs, ... }:

{
  flake.nixosModules.llamaVulkan = { pkgs, ... }: {
    environment.systemPackages = [
      inputs.llama-cpp.packages.${pkgs.stdenv.hostPlatform.system}.vulkan

      pkgs.python314Packages.huggingface-hub
    ];
  };
}
