{
  # Modules in this directory contribute to shared profiles.
  flake.modules.nixos.base = { lib, pkgs, ... }: {
    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      # Conservative defaults; build hosts can select their own parallelism.
      max-jobs = lib.mkDefault 1;
      cores = lib.mkDefault 2;
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
