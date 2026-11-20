# modules/llama/vulkan.nix
#
# llama.cpp through Vulkan. It needs no compute stack, only each card's graphics driver, so it reaches every GPU
# on the host, whatever the vendor: a fallback, and a baseline to measure the vendor backends against.
{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  flake.modules.nixos.llama-vulkan =
    { config, ... }:
    {
      imports = [ nixos.llama ];

      hardware.graphics.enable = true;

      llama.backends.vulkan = {
        package =
          (config.llama.packages.llama-cpp.override {
            useVulkan = true;
            useWebUi = false;
          }).overrideAttrs
            { webui = null; };

        devicePrefix = "Vulkan";
      };
    };
}
