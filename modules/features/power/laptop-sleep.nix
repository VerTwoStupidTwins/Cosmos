# Shared laptop power policy. Requires working swap-backed hibernation.
# Suspend on lid close, then hibernate after an hour on AC or battery.
{
  flake.modules.nixos."laptop-sleep" = {
    services = {
      logind.settings.Login = {
        HandleLidSwitch = "suspend-then-hibernate";
        HandleLidSwitchExternalPower = "suspend-then-hibernate";
        # Keep external displays usable while the laptop is docked.
        HandleLidSwitchDocked = "ignore";
      };

      # Protect unsaved sessions if the battery becomes critically low while awake.
      upower = {
        enable = true;
        usePercentageForPolicy = true;
        percentageCritical = 10;
        percentageAction = 5;
        criticalPowerAction = "Hibernate";
      };
    };

    systemd.sleep.settings.Sleep = {
      HibernateDelaySec = "60min";
      HibernateOnACPower = true;
    };
  };
}
