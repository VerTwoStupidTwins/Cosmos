{ ... }:

{
  flake.homeModules.twinsSsh = { ... }: {
    programs.ssh = {
      enable = true;

      # Declare our own defaults explicitly.
      enableDefaultConfig = false;

      settings = {
        "*" = {
          ForwardAgent = false;
          ForwardX11 = false;

          AddKeysToAgent = "yes";

          ServerAliveInterval = 30;
          ServerAliveCountMax = 3;

          HashKnownHosts = true;
          StrictHostKeyChecking = "ask";
          UpdateHostKeys = "yes";
        };

      };
    };
  };
}
