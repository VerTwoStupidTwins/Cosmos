# Shared laptop power policy for Niri laptops with working persistent hibernation swap.
# Suspend on lid close, then hibernate after 60 minutes, even on AC power.
{
  flake.modules.nixos."laptop-sleep" = { pkgs, ... }: {
    services = {
      logind.settings.Login = {
        HandleLidSwitch = "suspend-then-hibernate";
        HandleLidSwitchExternalPower = "suspend-then-hibernate";
        # Allow a docked laptop to drive external displays with its lid closed.
        HandleLidSwitchDocked = "ignore";
      };

      # Low-battery protection when awake; systemd handles sleeping transitions.
      upower = {
        enable = true;
        usePercentageForPolicy = true;
        percentageLow = 20;
        percentageCritical = 12;
        percentageAction = 8;
        criticalPowerAction = "Hibernate";
      };
    };

    systemd = {
      sleep.settings.Sleep = {
        HibernateDelaySec = "60min";
        HibernateOnACPower = true;
      };

      # Niri runs as a user service. Launch the locker with that session so
      # it has the imported Wayland environment and stops when Niri exits.
      user.services.swayidle = {
        description = "Lock Niri before suspend or hibernate";
        wantedBy = [ "niri.service" ];
        partOf = [ "niri.service" ];
        after = [ "niri.service" ];
        serviceConfig = {
          ExecStart = "${pkgs.swayidle}/bin/swayidle -w before-sleep '${pkgs.swaylock-effects}/bin/swaylock -f'";
          Restart = "on-failure";
        };
      };
    };
  };
}
