{ ... }:

{
  flake.nixosModules.laptop = { pkgs, ... }: {
    # Battery and power profiles
    services.power-profiles-daemon.enable = true;

    services.upower = {
      enable = true;

      percentageLow = 20;
      percentageCritical = 7;
      percentageAction = 3;

      # No disk swap or hibernation is configured.
      criticalPowerAction = "PowerOff";
    };

    services.thermald.enable = true;

    # Bluetooth
    hardware.bluetooth = {
      enable = true;
      powerOnBoot = true;
    };

    services.blueman.enable = true;

    # Use the S3 deep sleep mode already tested on Thoth
    boot.kernelParams = [ "mem_sleep_default=deep" ];

    # Lid handling
    services.logind.settings.Login = {
      HandleLidSwitch = "suspend";
      HandleLidSwitchExternalPower = "suspend";
      HandleLidSwitchDocked = "ignore";
      IdleAction = "ignore";
      HandleSuspendKey = "ignore";
    };

    systemd.services.thoth-charge-limit = {
      description = "Enable Chromebook battery charge limits";

      wantedBy = [ "multi-user.target" ];
      requires = [ "upower.service" ];
      after = [ "upower.service" ];

      serviceConfig.Type = "oneshot";

      script = ''
        for attempt in $(${pkgs.coreutils}/bin/seq 1 10); do
	  if ${pkgs.systemd}/bin/busctl --system call \
            org.freedesktop.UPower \
	    /org/freedesktop/UPower/devices/battery_BAT0 \
	    org.freedesktop.UPower.Device \
	    EnableChargeThreshold b true; then
	    exit 0
	  fi

	  ${pkgs.coreutils}/bin/sleep 1
	done

	exit 1
      '';
    };
  };

  flake.homeModules.laptop = { pkgs, ... }: {
    services.blueman-applet.enable = true;
    services.network-manager-applet.enable = true;

    home.packages = with pkgs; [
      brightnessctl
      playerctl
    ];
  };
}

