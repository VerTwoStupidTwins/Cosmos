{
  flake.modules.nixos.base = { pkgs, ... }: {
    environment.systemPackages = with pkgs; [
      git
      neovim
      curl
      htop
      lazygit
    ];
  };
}
