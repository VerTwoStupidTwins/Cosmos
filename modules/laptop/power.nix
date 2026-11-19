{
  flake.modules.nixos.laptop =
    { config, ... }:
    {
      # thermald only supports Intel CPUs; on AMD it fails its CPUID check and exits.
      services.thermald.enable = config.hardware.cpu.intel.updateMicrocode;

      services.tlp = {
        enable = true;
        settings = {
          # The EPP and platform-profile knobs need intel_pstate or amd_pstate and an ACPI
          # platform profile; TLP skips them where those are missing (tenjin's Zen+ chip runs
          # acpi-cpufreq and has no profile), so boost is what actually saves power there.
          CPU_ENERGY_PERF_POLICY_ON_AC = "balance_performance";
          CPU_ENERGY_PERF_POLICY_ON_BAT = "power";
          PLATFORM_PROFILE_ON_AC = "balanced";
          PLATFORM_PROFILE_ON_BAT = "low-power";
          CPU_BOOST_ON_AC = 1;
          CPU_BOOST_ON_BAT = 0;
          STOP_CHARGE_THRESH_BAT0 = 80;
        };
      };

      services.logind.settings.Login.HandleLidSwitch = "suspend-then-hibernate";
      systemd.sleep.settings.Sleep.HibernateDelaySec = "1h";
    };
}
