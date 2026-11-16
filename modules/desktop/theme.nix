# modules/desktop/theme.nix
# One colour scheme across the desktop, taken from the wallpaper.
#
# Build time: Stylix's palette generator gives every image in ./wallpapers a base16 palette,
# cached in the store next to the image. Stylix also themes GTK, Qt, the console and fonts,
# statically, from the default wallpaper.
#
# Runtime: `wallpaper` sets an image with awww and has matugen render the colour files that
# kitty, waybar, wofi, mako, hyprlock and niri include. A wallpaper built into the system uses
# its cached palette; any other image (one added since the last rebuild, or a path given to
# `wallpaper`) gets one from matugen's Material You colours, cached by the image's hash.
{ inputs, ... }:
let
  polarity = "dark";
  defaultWallpaper = "Frieren.png";
  # Where the repo is checked out; the wallpaper picker lists this folder.
  repoWallpapers = "/Cosmos/modules/desktop/wallpapers";
in
{
  flake.modules.nixos.wayland = {
    # Both compositors import the wayland module; the key keeps this part from applying twice.
    key = "cosmos/desktop/theme";

    imports = [
      inputs.stylix.nixosModules.stylix

      (
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          isImage = name: builtins.match ".*\\.(png|jpe?g|webp)" (lib.toLower name) != null;
          wallpapers = builtins.attrNames (
            lib.filterAttrs (name: type: type == "regular" && isImage name) (builtins.readDir ./wallpapers)
          );

          # Built exactly as Stylix builds its own, so the default wallpaper's palette is one derivation.
          paletteFor =
            image:
            pkgs.runCommand "palette.json" {
              inherit image polarity;
              nativeBuildInputs = [ config.stylix.paletteGenerator ];
            } ''palette-generator "$polarity" "$image" "$out"'';

          # The palette as matugen render data: base16.base0x.{default,dark,light}.color = "#rrggbb".
          matugenPalette =
            palette:
            pkgs.runCommand "palette-matugen.json" { nativeBuildInputs = [ pkgs.jq ]; } ''
              jq '{ base16: (to_entries
                    | map(select(.key | test("^base0[0-9A-Fa-f]$")))
                    | map(("#" + .value) as $c
                          | { key: (.key | ascii_downcase),
                              value: { default: { color: $c }, dark: { color: $c }, light: { color: $c } } })
                    | from_entries) }' ${palette} > "$out"
            '';

          # ~/.local/share/wallpapers: each image, and <image>.palette.json beside it.
          library = pkgs.linkFarm "wallpapers" (
            lib.concatMap (
              name:
              let
                image = ./wallpapers + "/${name}";
              in
              [
                {
                  inherit name;
                  path = image;
                }
                {
                  name = "${name}.palette.json";
                  path = matugenPalette (paletteFor image);
                }
              ]
            ) wallpapers
          );
        in
        {
          stylix = {
            enable = true;
            image = ./wallpapers + "/${defaultWallpaper}";
            inherit polarity;
            fonts.monospace = {
              package = pkgs.nerd-fonts.jetbrains-mono;
              name = "JetBrainsMono Nerd Font";
            };
          };

          home-manager.sharedModules = [
            (
              { config, lib, ... }:
              let
                stateDir = "${config.xdg.stateHome}/theme";
                pkill = "${pkgs.procps}/bin/pkill";
                c = name: "{{base16.${name}.default.hex}}";
                bare = name: "{{base16.${name}.default.hex_stripped}}";
                bases = map (n: "base0${n}") [
                  "0"
                  "1"
                  "2"
                  "3"
                  "4"
                  "5"
                  "6"
                  "7"
                  "8"
                  "9"
                  "a"
                  "b"
                  "c"
                  "d"
                  "e"
                  "f"
                ];

                templates = {
                  "colors.css" = {
                    text = lib.concatMapStrings (b: "@define-color ${b} ${c b};\n") bases;
                    # nixpkgs wraps waybar and kitty, so their process names are .waybar-wrapped, .kitty-wrapped.
                    hook = "${pkill} -USR2 -x '\\.?waybar(-wrapped)?' || true";
                  };

                  "kitty.conf" = {
                    text = ''
                      foreground ${c "base05"}
                      background ${c "base00"}
                      selection_foreground ${c "base00"}
                      selection_background ${c "base05"}
                      cursor ${c "base05"}
                      cursor_text_color ${c "base00"}
                      url_color ${c "base04"}
                      active_border_color ${c "base03"}
                      inactive_border_color ${c "base01"}
                      tab_bar_background ${c "base01"}
                      active_tab_foreground ${c "base05"}
                      active_tab_background ${c "base02"}
                      inactive_tab_foreground ${c "base04"}
                      inactive_tab_background ${c "base01"}
                      color0 ${c "base00"}
                      color1 ${c "base08"}
                      color2 ${c "base0b"}
                      color3 ${c "base0a"}
                      color4 ${c "base0d"}
                      color5 ${c "base0e"}
                      color6 ${c "base0c"}
                      color7 ${c "base05"}
                      color8 ${c "base03"}
                      color9 ${c "base08"}
                      color10 ${c "base0b"}
                      color11 ${c "base0a"}
                      color12 ${c "base0d"}
                      color13 ${c "base0e"}
                      color14 ${c "base0c"}
                      color15 ${c "base07"}
                      color16 ${c "base09"}
                      color17 ${c "base0f"}
                      color18 ${c "base01"}
                      color19 ${c "base02"}
                      color20 ${c "base04"}
                      color21 ${c "base06"}
                    '';
                    # kitty rereads its config on SIGUSR1.
                    hook = "${pkill} -USR1 -x '\\.?kitty(-wrapped)?' || true";
                  };

                  "mako" = {
                    text = ''
                      background-color=${c "base00"}
                      text-color=${c "base05"}
                      border-color=${c "base0d"}
                      progress-color=over ${c "base02"}

                      [urgency=high]
                      border-color=${c "base08"}
                    '';
                    hook = "${config.services.mako.package}/bin/makoctl reload || true";
                  };

                  # hyprlock reads this each time it starts.
                  "hyprlock.conf" = {
                    text = lib.concatMapStrings (b: "\$${b} = rgb(${bare b})\n") bases;
                  };

                  # niri watches included files and reloads them itself.
                  "niri.kdl" = {
                    text = ''
                      layout {
                          focus-ring {
                              active-color "${c "base0d"}"
                              inactive-color "${c "base03"}"
                              urgent-color "${c "base08"}"
                          }
                          border {
                              active-color "${c "base0d"}"
                              inactive-color "${c "base03"}"
                              urgent-color "${c "base08"}"
                          }
                      }
                    '';
                  };
                };

                matugenConfig = (pkgs.formats.toml { }).generate "matugen.toml" {
                  config = { };
                  templates = lib.mapAttrs' (
                    name: t:
                    lib.nameValuePair (lib.replaceStrings [ "." ] [ "-" ] name) (
                      {
                        input_path = pkgs.writeText "${name}.template" t.text;
                        output_path = "${stateDir}/${name}";
                      }
                      // lib.optionalAttrs (t ? hook) { post_hook = t.hook; }
                    )
                  ) templates;
                };

                wallpaper = pkgs.writeShellApplication {
                  name = "wallpaper";
                  runtimeInputs = with pkgs; [
                    awww
                    coreutils
                    diffutils
                    findutils
                    jq
                    matugen
                    wofi
                  ];
                  text = ''
                    library="''${XDG_DATA_HOME:-$HOME/.local/share}/wallpapers"
                    default=$library/${defaultWallpaper}
                    state="''${XDG_STATE_HOME:-$HOME/.local/state}/theme"
                    cache="''${XDG_CACHE_HOME:-$HOME/.cache}/wallpaper-palettes"
                    # The picker reads the checkout, so a wallpaper dropped in shows up before the
                    # rebuild that caches its palette; matugen colours it until then.
                    repo=${repoWallpapers}
                    [[ -d $repo ]] || repo=$library
                    mkdir -p "$state" "$cache"

                    usage() {
                      echo "usage: wallpaper [IMAGE | --restore | --render]"
                      echo "  (none)     pick from the wallpapers in $repo"
                      echo "  IMAGE      set IMAGE and theme the desktop from it"
                      echo "  --restore  set the current wallpaper again (run at login)"
                      echo "  --render   rewrite the colour files for the current wallpaper"
                    }

                    # Material You colours from matugen, laid out as a base16 palette.
                    # shellcheck disable=SC2016 # the $ are jq's
                    material_to_base16='
                      .colors as $c
                      | def m($k): $c[$k].dark.color as $v
                          | { default: { color: $v }, dark: { color: $v }, light: { color: $v } };
                      { base16: {
                          base00: m("surface"), base01: m("surface_container"),
                          base02: m("surface_container_highest"), base03: m("outline"),
                          base04: m("on_surface_variant"), base05: m("on_surface"),
                          base06: m("inverse_surface"), base07: m("primary_fixed"),
                          base08: m("error"), base09: m("tertiary_fixed_dim"),
                          base0a: m("secondary"), base0b: m("tertiary"),
                          base0c: m("primary_fixed_dim"), base0d: m("primary"),
                          base0e: m("secondary_fixed_dim"), base0f: m("on_error_container") } }'

                    # Prints the render data for an image: the repo's cached Stylix palette when the
                    # image is a repo wallpaper, otherwise matugen's, cached by the image's hash.
                    palette_for() {
                      local img=$1 name sum out
                      name=$(basename "$img")
                      if [[ -f $library/$name.palette.json ]] && cmp -s "$img" "$library/$name"; then
                        echo "$library/$name.palette.json"
                        return
                      fi
                      sum=$(sha256sum "$img" | cut -c1-32)
                      out=$cache/$sum.json
                      if [[ ! -f $out ]]; then
                        matugen image "$img" --mode dark --source-color-index 0 --dry-run --json hex \
                          | jq "$material_to_base16" > "$out.tmp"
                        mv "$out.tmp" "$out"
                      fi
                      echo "$out"
                    }

                    render() {
                      matugen --config ${matugenConfig} json "$(palette_for "$1")" > /dev/null
                    }

                    show() {
                      # At login the daemon may still be starting; wait up to 5 seconds for it.
                      local deadline=$((SECONDS + 5))
                      until awww query > /dev/null 2>&1; do
                        (( SECONDS >= deadline )) && { echo "wallpaper: awww-daemon isn't running" >&2; return 0; }
                        sleep 0.2
                      done
                      awww img --transition-type grow "$1"
                    }

                    current() {
                      local img
                      img=$(cat "$state/current" 2> /dev/null || true)
                      [[ -f $img ]] || img=$default
                      echo "$img"
                    }

                    apply() {
                      local img
                      img=$(realpath -s "$1")
                      render "$img"
                      echo "$img" > "$state/current"
                      ln -sfn "$img" "$state/wallpaper"
                      show "$img"
                    }

                    pick() {
                      local -A paths=()
                      local img label choice
                      while IFS= read -r -d "" img; do
                        label=$(basename "$img")
                        paths[''${label%.*}]=$img
                      done < <(find -L "$repo" -maxdepth 1 -type f \
                                 \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) \
                                 -print0 2> /dev/null)
                      choice=$(printf '%s\n' "''${!paths[@]}" | sort | wofi --dmenu --prompt Wallpaper) || exit 0
                      [[ -n $choice ]] && apply "''${paths[$choice]}"
                    }

                    case "''${1:-}" in
                      "") pick ;;
                      --restore) apply "$(current)" ;;
                      --render)
                        img=$(current)
                        render "$img"
                        ln -sfn "$img" "$state/wallpaper"
                        ;;
                      -h | --help) usage ;;
                      *) [[ -f $1 ]] || { usage >&2; exit 1; }; apply "$1" ;;
                    esac
                  '';
                };
              in
              {
                home.packages = [ wallpaper ];
                services.awww.enable = true;
                xdg.dataFile.wallpapers.source = library;

                # Rewrite the colour files on every switch, so template changes land straight away and
                # the first login already has them.
                home.activation.wallpaperTheme = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
                  run ${wallpaper}/bin/wallpaper --render
                '';

                # matugen supplies these apps' colours at runtime; Stylix keeps their fonts.
                stylix.targets = {
                  kitty.colors.enable = false;
                  waybar.enable = false;
                  wofi.enable = false;
                  mako.enable = false;
                  hyprlock.enable = false;
                  hyprland.enable = false;
                  hyprpaper.enable = false;
                  # Needs declared Firefox profiles, and Firefox here keeps its own.
                  firefox.enable = false;
                };

                programs.kitty.extraConfig = "include ${stateDir}/kitty.conf";
                services.mako.settings.include = "${stateDir}/mako";
                programs.hyprlock.settings.source = "${stateDir}/hyprlock.conf";
              }
            )
          ];
        }
      )
    ];
  };
}
