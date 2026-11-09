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

        xdg.configFile."1Password/ssh/agent.toml".text = ''
          [[ssh-keys]]
          vault = "Cosmos Runtime"
	  [[ssh-keys]]
	  vault = "Private"
        '';

	programs.git.signing = {
	  format = "ssh";
	  key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKa1QvCU/Rrvh44eY4UZT0qunJkwvNYqt7F5rrK7IJno";
	  signByDefault = true;
	};
      }
    ];
  };
}
