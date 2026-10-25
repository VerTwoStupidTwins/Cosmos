# Dendritic feature contributions: tools selected for the Linux workstations.
# No shell aliases, dotfiles, settings, or themes are declared here.
{
  flake.modules.nixos.base = { pkgs, ... }: {
    programs.fish.enable = true;

    environment.systemPackages = with pkgs; [
      eza
      bottom
      neovim
      starship
      zellij
      fzf
      fd
      zoxide
      bat
      jq
      yq
      sops
      lazygit
      yazi
    ];
  };

  flake.modules.nixos.workstation = { pkgs, ... }: {
    environment.systemPackages = with pkgs; [
      alacritty
      kitty
    ];
  };
}
