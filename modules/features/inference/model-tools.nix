# Native model downloads, without an imperative Python environment.
{
  flake.modules.nixos."model-tools" = { pkgs, ... }: {
    environment.systemPackages = [ pkgs.python3Packages.huggingface-hub ];
  };
}
