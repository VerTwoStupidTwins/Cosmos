{
  flake.modules.nixos."niri-desktop" = { pkgs, ... }: {
    security.polkit.enable = true;

    systemd.user.services.lxqt-policykit-agent = {
      description = "LXQt Polkit Authentication Agent";

      wantedBy = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];

      serviceConfig = {
        ExecStart =
          "${pkgs.lxqt.lxqt-policykit}/bin/lxqt-policykit-agent";

        Restart = "on-failure";
        RestartSec = 2;
      };
    };
  };
}
