# Shared laptop power and Wayland locking with persistent hibernation swap.
# Suspend on lid close, then hibernate after 60 minutes, even on AC power.
{
  flake.modules.nixos."laptop-sleep" = { pkgs, ... }: {
    # Authentication and locker tools belong to the shared policy, not a compositor.
    security.pam.services.swaylock = { };
    environment.systemPackages = with pkgs; [
      swayidle
      swaylock-effects
    ];

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
      # Enforce battery protection even when no desktop client activates UPower.
      services.upower.wantedBy = [ "multi-user.target" ];

      sleep.settings.Sleep = {
        HibernateDelaySec = "60min";
        HibernateOnACPower = true;
      };

      # Niri and Mango import their Wayland environment before activating this
      # target. Stop the single listener on logout, then start it with the next
      # session's environment; do not run a separate listener per compositor.
      user.services.swayidle = {
        description = "Lock the Wayland session on request and before sleep";
        wantedBy = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        after = [ "graphical-session.target" ];
        unitConfig.ConditionEnvironment = "WAYLAND_DISPLAY";
        serviceConfig = {
          # Ignore additive user swayidle configs; only these events are enabled.
          # -w plus swaylock -f waits for the lock to be established before sleep.
          ExecStart = "${pkgs.swayidle}/bin/swayidle -w -C /dev/null lock '${pkgs.swaylock-effects}/bin/swaylock -f' before-sleep '${pkgs.swaylock-effects}/bin/swaylock -f'";
          Restart = "on-failure";
        };
      };
    };
  };
}
