{
  flake.modules.nixos.desktop = {
    programs._1password.enable = true;

    programs._1password-gui = {
      enable = true;
      polkitPolicyOwners = [ "twins" ];
    };

    home-manager.sharedModules = [
      {
        home.sessionVariables.SSH_AUTH_SOCK = "$HOME/.1password/agent.sock";

        home.file.".ssh/github.pub".text =
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMXU4Nx8Z3Vst+FwsXIlz6bjJLtvU4ZwMUd9Rw/5mZbc";

        xdg.configFile."1Password/ssh/agent.toml".text = ''
          	  [[ssh-keys]]
                    vault = "Cosmos Runtime"
                    [[ssh-keys]]
                    vault = "Private"
        '';

        programs.git.signing = {
          format = "ssh";
          key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMXU4Nx8Z3Vst+FwsXIlz6bjJLtvU4ZwMUd9Rw/5mZbc";
          signByDefault = true;
        };

        programs.ssh = {
          enable = true;
          enableDefaultConfig = false;
          settings."github.com" = {
            IdentityFile = "~/.ssh/github.pub";
            IdentitiesOnly = true;
          };
        };
      }
    ];
  };
}
