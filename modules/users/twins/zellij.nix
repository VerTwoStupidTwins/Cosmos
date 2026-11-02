{ ... }:

{
  flake.homeModules.twinsZellij = { lib, ... }: {
    programs.zellij = {
      enable = true;

      # Disable the generic autostart.
      # We'll explicitly attach to "main" below.
      enableFishIntegration = false;

      settings = {
        theme = "rose-pine-moon";
        default_layout = "compact";
        simplified_ui = true;
        pane_frames = true;
        mouse_mode = true;
        scroll_buffer_size = 20000;
        copy_on_select = true;
      };

      # Keep your existing Rose Pine Moon theme here.
      themes."rose-pine-moon" = ''
        themes {
          rose-pine-moon {
            fg "#e0def4"
            bg "#232136"
            black "#393552"
            red "#eb6f92"
            green "#3e8fb0"
            yellow "#f6c177"
            blue "#9ccfd8"
            magenta "#c4a7e7"
            cyan "#9ccfd8"
            white "#e0def4"
            orange "#ea9a97"
          }
        }
      '';
    };

    # Start or reconnect to the named main session.
    programs.fish.interactiveShellInit = ''
      if status is-interactive
        if not set -q ZELLIJ
          if not set -q SSH_CONNECTION
            if test "$TERM" != dumb
              zellij attach --create main
            end
          end
        end
      end
    '';

  };
}
