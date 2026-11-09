{
  flake.modules.nixos.base = {
    services.openssh = {
      enable = true;
      openFirewall = false;
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
    };

    networking.firewall.interfaces."nb-wt0".allowedTCPPorts = [ 22 ];

    networking.firewall.extraCommands = ''
      iptables -A nixos-fw -p tcp --dport 22 -s 10.77.10.0/24 -j nixos-fw-accept
    '';
  };
}
