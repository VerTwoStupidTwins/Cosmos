# modules/laptop/convertible.nix
# 2-in-1 laptops: the screen follows the accelerometer in tablet mode, and an on-screen keyboard
# comes up for text fields. iio-sensor-proxy reads the sensors; the Quickshell bar (Tablet.qml)
# follows the tablet-mode switch and runs iio-niri and wvkbd only while the laptop is folded back,
# so a laptop on a desk never rotates. libinput already turns the keyboard and touchpad off in
# tablet mode. Pulling the stylus from its garage brings up the bar's pen menu (Pen.qml).
{
  flake.modules.nixos.convertible =
    { pkgs, ... }:
    {
      # On cros-ec Chromebooks the kernel labels the accelerometers accel-display and accel-base,
      # which iio-sensor-proxy uses to pick the screen's.
      hardware.sensor.iio.enable = true;

      # Handwriting and sketching for the pen, opened from the bar's pen menu (and the launcher).
      environment.systemPackages = [ pkgs.rnote ];

      # The tablet-mode switch, and the pen garage where there is one, at fixed paths the logged-in
      # user can read: the bar watches both with evtest (Tablet.qml, Pen.qml).
      # Its own file, numbered before 73-seat-late.rules, which is where uaccess tags take effect;
      # services.udev.extraRules lands in 99-local.rules, too late for that.
      services.udev.packages = [
        (pkgs.writeTextDir "lib/udev/rules.d/70-convertible.rules" ''
          SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="Tablet Mode Switch", SYMLINK+="input/tablet-mode", TAG+="uaccess"
          SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="PRP0001:01", SYMLINK+="input/pen-garage", TAG+="uaccess"
        '')
      ];
    };
}
