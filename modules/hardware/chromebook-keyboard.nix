
{ ... }:

{
  flake.nixosModules.chromebookKeyboard =
    { config, ... }:
    {
      # Enable system-wide keyboard remapping.
      services.keyd.enable = true;

      environment.systemPackages = [
        config.services.keyd.package
      ];

      # Use the Chromebook-specific mapping generated
      # by WeirdTreeThing/cros-keyboard-map.
      environment.etc."keyd/cros.conf".source =
        ./cros.conf;

      # Ensure keyd reloads when our mapping changes.
      systemd.services.keyd.restartTriggers = [
        config.environment.etc."keyd/cros.conf".source
      ];

      # Treat keyd's virtual keyboard as an internal
      # keyboard for libinput.
      environment.etc."libinput/local-overrides.quirks".text = ''
        [keyd virtual keyboard]
        MatchName=keyd virtual keyboard
        AttrKeyboardIntegration=internal
        ModelTabletModeNoSuspend=1
      '';
    };
}

