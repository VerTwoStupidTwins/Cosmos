# modules/desktop/chat-theme.nix
# The chat site (chat.<domain>, served by the agent on lugh) wears the desktop's colours: whenever `wallpaper` rewrites
# the theme's quickshell.json (theme.nix), this sends the palette to the agent, which serves it to every browser, phone
# included. Also sent at login, in case lugh missed a change. A failed send changes nothing and is retried next time.
{ ... }:
{
  flake.modules.nixos.wayland =
    { config, pkgs, ... }:
    let
      tokenFile = config.sops.secrets.chat-theme-token.path;
      url = "https://chat.gatica.one/api/theme";
    in
    {
      key = "cosmos/desktop/chat-theme";

      sops.secrets.chat-theme-token = {
        sopsFile = ../../secrets/common.yaml;
        owner = "twins";
        mode = "0400";
      };

      home-manager.sharedModules = [
        (
          { config, ... }:
          let
            palette = "${config.xdg.stateHome}/theme/quickshell.json";
            push = pkgs.writeShellScript "chat-theme-push" ''
              [ -s "${palette}" ] && [ -r "${tokenFile}" ] || exit 0
              # The token goes in a header file, so it never shows in the process list.
              header=$(${pkgs.coreutils}/bin/mktemp)
              trap '${pkgs.coreutils}/bin/rm -f "$header"' EXIT
              printf 'authorization: Bearer %s\n' "$(${pkgs.coreutils}/bin/cat "${tokenFile}")" > "$header"
              exec ${pkgs.curl}/bin/curl -fsS --max-time 15 --retry 3 --retry-all-errors \
                -H @"$header" -H 'content-type: application/json' --data-binary @"${palette}" "${url}"
            '';
          in
          {
            systemd.user.services.chat-theme = {
              Unit.Description = "Send the desktop palette to the chat site";
              Service = {
                Type = "oneshot";
                ExecStart = "${push}";
              };
              Install.WantedBy = [ "graphical-session.target" ];
            };
            systemd.user.paths.chat-theme = {
              Unit.Description = "Watch the desktop palette for the chat site";
              Path.PathChanged = palette;
              Install.WantedBy = [ "default.target" ];
            };
          }
        )
      ];
    };
}
