# modules/features/hyprland.nix
{
  flake.modules.nixos.hyprland = {
    programs.hyprland.enable = true;
    programs.hyprlock.enable = true; # registers the PAM service hyprlock needs
    
    services.hypridle.enable = true;

    home-manager.sharedModules = [
      (
        { pkgs, ... }:
        {
          home.packages = with pkgs; [
            brightnessctl
            playerctl
            grim
            slurp
            wl-clipboard
          ];

          programs.foot.enable = true;
          programs.fuzzel.enable = true;
          programs.waybar.enable = true;
          services.mako.enable = true;

	  services.hyprpolkitagent.enable = true;

          programs.hyprlock = {
            enable = true;
            settings = {
              background = [ { color = "rgb(1e1e2e)"; } ];
              input-field = [
                {
                  size = "300, 50";
                  position = "0, 0";
                  halign = "center";
                  valign = "center";
                }
              ];
            };
          };

          services.hypridle = {
            enable = true;
            settings = {
              general = {
                lock_cmd = "pidof hyprlock || hyprlock";
                before_sleep_cmd = "loginctl lock-session";
              };
              listener = [
                {
                  timeout = 300;
                  on-timeout = "loginctl lock-session";
                }
                {
                  timeout = 900;
                  on-timeout = "systemctl suspend-then-hibernate";
                }
              ];
            };
          };

          wayland.windowManager.hyprland = {
            enable = true;
            package = null; # already installed by the NixOS module
            portalPackage = null;
            configType = "lua";
            settings = { };
            extraConfig = ''
              local mod = "SUPER"

              hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
              hl.env("XCURSOR_SIZE", "24")

              hl.config({
                general = { gaps_in = 4, gaps_out = 8, border_size = 2 },
                decoration = { rounding = 8, blur = { enabled = false } },
                input = {
                  kb_layout = "us",
                  follow_mouse = 1,
                  touchpad = { natural_scroll = true },
                },
                misc = { disable_hyprland_logo = true },
              })

              hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })

              hl.on("hyprland.start", function()
                hl.exec_cmd("waybar")
		hl.exec_cmd("systemctl --user start hyprpolkitagent")
		hl.exec_cmd("1password --silent")
              end)

              -- Apps and session
              hl.bind(mod .. " + Return", hl.dsp.exec_cmd("foot"))
              hl.bind(mod .. " + D", hl.dsp.exec_cmd("fuzzel"))
              hl.bind(mod .. " + L", hl.dsp.exec_cmd("loginctl lock-session"))
              hl.bind(mod .. " + SHIFT + E", hl.dsp.exit())

              -- Windows
              hl.bind(mod .. " + Q", hl.dsp.window.close())
              hl.bind(mod .. " + F", hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }))
              hl.bind(mod .. " + left", hl.dsp.focus({ direction = "left" }))
              hl.bind(mod .. " + right", hl.dsp.focus({ direction = "right" }))
              hl.bind(mod .. " + up", hl.dsp.focus({ direction = "up" }))
              hl.bind(mod .. " + down", hl.dsp.focus({ direction = "down" }))
              hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })

              -- Workspaces 1-10 (0 key is workspace 10)
              for i = 1, 10 do
                local key = i % 10
                hl.bind(mod .. " + " .. key, hl.dsp.focus({ workspace = i }))
                hl.bind(mod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
              end

              -- Screenshot a region to the clipboard
              hl.bind(mod .. " + S", hl.dsp.exec_cmd('grim -g "$(slurp)" - | wl-copy'))

              -- Media and brightness keys
              local held = { locked = true, repeating = true }
              hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), held)
              hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"), held)
              hl.bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"), { locked = true })
              hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("brightnessctl set 5%+"), held)
              hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl set 5%-"), held)
            '';
          };
        }
      )
    ];
  };
}
