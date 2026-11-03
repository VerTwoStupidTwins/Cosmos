{ ... }:

{
  flake.nixosModules.llamaVulkan = { pkgs, ... }: {
    environment.systemPackages = [
      (pkgs.llama-cpp.override {
        vulkanSupport = true;
      })
    ];
  };
}
