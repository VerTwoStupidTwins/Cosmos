
{ ... }:

{
  flake.nixosModules.desktopUsability = { ... }: {
    # Proper Thunar integration
    programs.thunar.enable = true;
    services.gvfs.enable = true;
    services.tumbler.enable = true;

    # GTK settings support
    programs.dconf.enable = true;
  };

  flake.homeModules.desktopUsability =
    { pkgs, ... }:

    let
      clipboardPicker = pkgs.writeShellApplication {
        name = "cliphist-picker";

        runtimeInputs = with pkgs; [
          cliphist
          wofi
          wl-clipboard
        ];

        text = ''
          entry="$(cliphist list | wofi --dmenu --prompt 'Clipboard> ')" || exit 0
          [ -n "$entry" ] || exit 0

          printf '%s\n' "$entry" |
            cliphist decode |
            wl-copy
        '';
      };
    in
    {

      # GTK appearance
      gtk = {
        enable = true;
        colorScheme = "dark";

        iconTheme = {
          name = "rose-pine-moon";
          package = pkgs.rose-pine-icon-theme;
        };

        cursorTheme = {
          name = "Bibata-Modern-Ice";
          package = pkgs.bibata-cursors;
          size = 24;
        };
      };

      # Default directory handler
      xdg.mimeApps = {
        enable = true;

        defaultApplications = {
          "inode/directory" = "thunar.desktop";
        };
      };

      home.packages = with pkgs; [
        clipboardPicker
        libnotify
        adwaita-icon-theme
      ];
    };
}

