{ ... }:

{
  flake.nixosModules.llamaVulkan = { pkgs, ... }: {
    environment.systemPackages = [
      (pkgs.llama-cpp.override {
        vulkanSupport = true;
      })
      pkgs.python314Packages.huggingface-hub
    ];
  };
}
