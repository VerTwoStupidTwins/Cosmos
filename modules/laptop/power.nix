{
  flake.modules.nixos.laptop = {
    services.thermald.enable = true;

    services.tlp = {
      enable = true;
      settings = {
        CPU_ENERGY_PERF_POLICY_ON_AC = "balance_performance";
        CPU_ENERGY_PERF_POLICY_ON_BAT = "power";
        PLATFORM_PROFILE_ON_AC = "balanced";
        PLATFORM_PROFILE_ON_BAT = "low-power";
        STOP_CHARGE_THRESH_BAT0 = 80;
      };
    };

    services.logind.settings.Login.HandleLidSwitch = "suspend-then-hibernate";
    systemd.sleep.settings.Sleep.HibernateDelaySec = "1h";
  };
}
