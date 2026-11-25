# modules/desktop/files.nix
# Files on the desktop: Thunar, with gvfs for the trash, network shares and phones, udisks2 and
# udiskie so USB drives mount on their own (a notification says so, and the bar's DRV plate lists
# them), tumbler for thumbnails, File Roller behind Thunar's "Extract here", and Loupe for viewing
# images (GTK4, so it follows the theme, with pinch-zoom and swipe on the touchscreen).
{
  flake.modules.nixos.desktop =
    { pkgs, ... }:
    {
      programs.thunar = {
        enable = true;
        plugins = with pkgs; [
          thunar-archive-plugin
          thunar-volman
        ];
      };
      # Remembers Thunar's settings (view, sidebar) between sessions.
      programs.xfconf.enable = true;

      services.gvfs.enable = true;
      services.udisks2.enable = true;
      services.tumbler.enable = true;

      home-manager.sharedModules = [
        (
          { pkgs, lib, ... }:
          {
            home.packages = [
              pkgs.file-roller
              pkgs.loupe
            ];

            # Mounts drives as they're plugged in, under /run/media/twins; the bar's DRV plate
            # unmounts and ejects them.
            services.udiskie = {
              enable = true;
              automount = true;
              notify = true;
              # The bar's DRV readout and plate stand in for its tray icon.
              tray = "never";
            };

            # This file is read-only once managed here, so the link handlers apps had written into it
            # (Claude Code's and Telegram's) are kept here too.
            xdg.mimeApps = {
              enable = true;
              defaultApplications = {
                "inode/directory" = "thunar.desktop";
                "x-scheme-handler/claude-cli" = "claude-code-url-handler.desktop";
                "x-scheme-handler/tg" = "org.telegram.desktop.desktop";
                "x-scheme-handler/tonsite" = "org.telegram.desktop.desktop";
                "x-scheme-handler/ton" = "org.telegram.desktop.desktop";
              }
              # Images open in Loupe rather than Krita, which had claimed PNGs; Krita stays under "Open with".
              // lib.genAttrs [
                "image/png"
                "image/jpeg"
                "image/webp"
                "image/gif"
                "image/apng"
                "image/avif"
                "image/heic"
                "image/jxl"
                "image/bmp"
                "image/tiff"
                "image/svg+xml"
              ] (_: "org.gnome.Loupe.desktop");
            };
          }
        )
      ];
    };
}
