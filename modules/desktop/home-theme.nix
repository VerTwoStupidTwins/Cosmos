# modules/desktop/home-theme.nix
# The start page (home.gatica.one, homepage.nix on lugh) wears the desktop's colours: whenever `wallpaper` rewrites the
# theme's quickshell.json (theme.nix), this turns the palette into CSS variables and puts it on lugh, which serves it as
# /theme.css to every browser, phone included. Also sent at login, in case lugh missed a change. A failed send changes
# nothing and is retried next time.
{ ... }:
{
  flake.modules.nixos.wayland =
    { config, pkgs, ... }:
    let
      tokenFile = config.sops.secrets.chat-theme-token.path;
      url = "https://home.gatica.one/theme.css";

      # base00…base0f and the accent, each as --key:#rrggbb and --key-rgb:r g b (for styles that add their own alpha).
      # Only well-formed colours get through.
      toCss = pkgs.writeText "palette-to-css.jq" ''
        def nibble: {"0":0,"1":1,"2":2,"3":3,"4":4,"5":5,"6":6,"7":7,"8":8,"9":9,"a":10,"b":11,"c":12,"d":13,"e":14,"f":15}[.];
        def byte: (.[0:1] | nibble) * 16 + (.[1:2] | nibble);
        . as $palette
        | [ ([range(0; 16)] | map("base0" + ("0123456789abcdef"[.:.+1]))) + ["accent"]
            | .[]
            | . as $key
            | ($palette[$key] // "" | ascii_downcase)
            | select(test("^#[0-9a-f]{6}$"))
            | "--\($key):\(.);--\($key)-rgb:\(.[1:3] | byte) \(.[3:5] | byte) \(.[5:7] | byte);" ]
        | ":root{" + join("") + "}"
      '';
    in
    {
      key = "cosmos/desktop/home-theme";

      # The start page checks it before taking a new palette.
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
            push = pkgs.writeShellScript "home-theme-push" ''
              [ -s "${palette}" ] && [ -r "${tokenFile}" ] || exit 0
              css=$(${pkgs.coreutils}/bin/mktemp)
              header=$(${pkgs.coreutils}/bin/mktemp)
              trap '${pkgs.coreutils}/bin/rm -f "$css" "$header"' EXIT
              ${pkgs.jq}/bin/jq -r -f ${toCss} "${palette}" > "$css"
              # The token goes in a header file, so it never shows in the process list.
              printf 'authorization: Bearer %s\n' "$(${pkgs.coreutils}/bin/cat "${tokenFile}")" > "$header"
              exec ${pkgs.curl}/bin/curl -fsS --max-time 15 --retry 3 --retry-all-errors -X PUT \
                -H @"$header" -H 'content-type: text/css' --data-binary @"$css" "${url}"
            '';
          in
          {
            systemd.user.services.home-theme = {
              Unit.Description = "Send the desktop palette to the start page";
              Service = {
                Type = "oneshot";
                ExecStart = "${push}";
              };
              Install.WantedBy = [ "graphical-session.target" ];
            };
            systemd.user.paths.home-theme = {
              Unit.Description = "Watch the desktop palette for the start page";
              Path.PathChanged = palette;
              Install.WantedBy = [ "default.target" ];
            };
          }
        )
      ];
    };
}
