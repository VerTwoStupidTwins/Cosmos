# modules/features/krita.nix
{
  # Krita, with Krita AI Diffusion drawing through lugh's ComfyUI (comfyui.nix) over NetBird.
  flake.modules.nixos.krita =
    { pkgs, ... }:
    let
      # 1.54 is the first version for Krita 6, which nixpkgs ships. The plugin keeps its settings and logs in
      # ~/.local/share/krita/ai_diffusion, so it can run from the store.
      aiDiffusion = pkgs.fetchzip {
        url = "https://github.com/Acly/krita-ai-diffusion/releases/download/v1.54.0-pre/krita_ai_diffusion-1.54.0-pre.zip";
        hash = "sha256-0okMfg1XOyopbWmTzGESN0jVCCNP0hR5B3bomYsAj3Q=";
        stripRoot = false;
      };
    in
    {
      home-manager.sharedModules = [
        {
          home.packages = [ pkgs.krita ];
          xdg.dataFile."krita/pykrita/ai_diffusion".source = "${aiDiffusion}/ai_diffusion";
          xdg.dataFile."krita/pykrita/ai_diffusion.desktop".source = "${aiDiffusion}/ai_diffusion.desktop";

          # ComfyUI's own web page, through the same gate on lugh (comfyui.nix, gatePort), in a Firefox
          # window of its own.
          xdg.desktopEntries.comfyui = {
            name = "ComfyUI";
            genericName = "Image generation on lugh";
            comment = "Node-based image generation, running on lugh's B580";
            exec = "firefox --new-window http://lugh.netbird.cloud:8189";
            icon = "applications-graphics";
            categories = [
              "Graphics"
              "Network"
            ];
          };
        }
      ];
    };
}
