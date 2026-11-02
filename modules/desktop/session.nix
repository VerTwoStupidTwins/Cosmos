
{ ... }:

{
  flake.nixosModules.session = { ... }: {
    security.pam.services.hyprlock = { };
  };

  flake.homeModules.session =
    { pkgs, ... }:

    let
      lock = pkgs.writeShellScript "thoth-lock" ''
        if ! ${pkgs.procps}/bin/pgrep \
          -u "$(${pkgs.coreutils}/bin/id -u)" \
          -x hyprlock > /dev/null; then

          ${pkgs.hyprlock}/bin/hyprlock \
            --immediate-render \
            </dev/null >/dev/null 2>&1 &

          ${pkgs.coreutils}/bin/sleep 1
        fi
      '';

      suspendOnBattery = pkgs.writeShellScript
        "thoth-suspend-on-battery" ''
          if ${pkgs.systemd}/bin/busctl --system get-property \
            org.freedesktop.UPower \
            /org/freedesktop/UPower \
            org.freedesktop.UPower OnBattery \
            | ${pkgs.gnugrep}/bin/grep -q '^b true$'; then

            ${pkgs.systemd}/bin/systemctl suspend
          fi
        '';

      idleTenMinutes = pkgs.writeShellScript
        "thoth-idle-ten-minutes" ''
          ${pkgs.niri}/bin/niri msg action power-off-monitors
          ${suspendOnBattery}
        '';

      wakeDisplay =
        "${pkgs.niri}/bin/niri msg action power-on-monitors";

    in
    {
      programs.hyprlock = {
        enable = true;

        settings = {
          general = {
            hide_cursor = true;
            immediate_render = true;
          };

          background = [
            {
              monitor = "";
              color = "rgb(35, 33, 54)";
            }
          ];

          input-field = [
            {
              monitor = "";
              size = "280, 55";
              position = "0, 0";
              dots_center = true;

              font_color = "rgb(224, 222, 244)";
              inner_color = "rgb(42, 39, 63)";
              outer_color = "rgb(196, 167, 231)";
            }
          ];
        };
      };

      
services.swayidle = {
  enable = true;

  # This is also Home Manager's default.
  extraArgs = [ "-w" ];

  timeouts = [
    {
      timeout = 300;
      command =
        "${pkgs.systemd}/bin/loginctl lock-session";
    }

    {
      timeout = 600;
      command = "${idleTenMinutes}";
      resumeCommand = wakeDisplay;
    }
  ];

  events = {
    lock = "${lock}";
    before-sleep = "${lock}";
    after-resume = wakeDisplay;
  };
};

};


}

