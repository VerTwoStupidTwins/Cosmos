# modules/features/llm.nix
{ inputs, ... }:
{
  flake.modules.nixos.llm =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        inputs.llama-cpp.packages.${pkgs.stdenv.hostPlatform.system}.vulkan
        pkgs.python3Packages.huggingface-hub
      ];

      systemd.tmpfiles.rules = [ "d /models 0775 twins users -" ];
    };
}
