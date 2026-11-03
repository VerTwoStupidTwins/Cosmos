{ self, inputs, ... }:

{
  flake.homeModules.twins = { pkgs, ... }: {
    imports = [
      self.homeModules.twinsShell
      self.homeModules.twinsDevelopment
      self.homeModules.twinsZellij
      self.homeModules.twinsYazi
      self.homeModules.twinsNeovim

      self.homeModules.twinsGit
      self.homeModules.twinsSsh
    ];

    home.stateVersion = "26.05";

    home.packages = with pkgs; [
      inputs.codex-cli-nix.packages.x86_64-linux.default
    ];
  };
}
