{ ... }:

{
  flake.nixosModules.sshServer = { ... }: {
    services.openssh = {
      enable = true;
      openFirewall = true;

      settings = {
        PubkeyAuthentication = true;

        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;

        PermitRootLogin = "no";
        X11Forwarding = false;
      };
    };
  };
}
