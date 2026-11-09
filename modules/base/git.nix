{
  flake.modules.nixos.base = {
    home-manager.sharedModules = [
      {
        programs.git = {
          enable = true;
          settings = {
            user = {
              name = "TwoStupidTwins";
              email = "twins@email.com";
            };
            init.defaultBranch = "main";
            pull.rebase = true;
            push.autoSetupRemote = true;
            fetch.prune = true;
          };
        };
      }
    ];
  };
}
