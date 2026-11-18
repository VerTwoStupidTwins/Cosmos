# modules/laptop/convertible.nix
# 2-in-1 laptops: the screen follows the accelerometer in tablet mode, and an on-screen keyboard
# comes up for text fields. iio-sensor-proxy reads the sensors; the Quickshell bar (Tablet.qml)
# follows the tablet-mode switch and runs iio-niri and wvkbd only while the laptop is folded back,
# so a laptop on a desk never rotates. libinput already turns the keyboard and touchpad off in
# tablet mode.
{
  flake.modules.nixos.convertible = {
    # On cros-ec Chromebooks the kernel labels the accelerometers accel-display and accel-base,
    # which iio-sensor-proxy uses to pick the screen's.
    hardware.sensor.iio.enable = true;

    # The tablet-mode switch, and the pen garage where there is one, at fixed paths the logged-in
    # user can read: the bar watches the first with evtest, and the second is there for later.
    services.udev.extraRules = ''
      SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="Tablet Mode Switch", SYMLINK+="input/tablet-mode", TAG+="uaccess"
      SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="PRP0001:01", SYMLINK+="input/pen-garage", TAG+="uaccess"
    '';
  };
}
