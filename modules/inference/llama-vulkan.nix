{ inputs, ... }:

{
  flake.nixosModules.llamaVulkan = { pkgs, ... }: {
    environment.systemPackages = [
      inputs.llama-cpp.packages.x86-linux.vulkan

      pkgs.python314Packages.huggingface-hub
    ];
  };
}
