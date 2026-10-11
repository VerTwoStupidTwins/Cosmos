{
  # Modules in this directory contribute to shared profiles.
  flake.modules.nixos.base = { pkgs, ... }: {
    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      max-jobs = 1;
      cores = 2;
    };
    time.timeZone = "America/Los_Angeles";
    i18n.defaultLocale = "en_US.UTF-8";
    console.keyMap = "us";
    environment.systemPackages = with pkgs; [
      git
      curl
      nano
      neovim
      ripgrep
    ];
  };
}
