# modules/desktop/editors.nix
# Zed for the desktop, in Helix mode, and Helix itself in the terminal (every host has plain Helix as
# $EDITOR, modules/base/packages.nix). Both share one set of language servers and formatters from nixpkgs,
# and take their colours from the wallpaper (theme.nix).
{
  flake.modules.nixos.desktop = {
    home-manager.sharedModules = [
      (
        { lib, pkgs, ... }:
        let
          # On PATH for Helix and inside Zed's wrapper, so neither downloads its own (downloaded
          # binaries don't run on NixOS).
          tools = with pkgs; [
            # Nix and shell; nixfmt matches the repo's treefmt.
            nixd
            nixfmt
            bash-language-server
            shellcheck
            shfmt
            # Rust. rust-analyzer needs cargo and rustc to read a project.
            rust-analyzer
            rustfmt
            clippy
            cargo
            rustc
            # Web and Python.
            nodejs
            typescript
            typescript-language-server
            vtsls
            svelte-language-server
            vscode-langservers-extracted
            prettier
            basedpyright
            ruff
            # QML (the bar), Markdown, TOML, KDL (niri.kdl).
            kdePackages.qtdeclarative
            marksman
            taplo
            kdlfmt
          ];
        in
        {
          home.packages = tools;

          programs.helix = {
            enable = true;
            settings = {
              # The wallpaper's palette (theme.nix writes it and reloads open editors).
              theme = "cosmos";
              editor = {
                line-number = "relative";
                cursorline = true;
                color-modes = true;
                bufferline = "multiple";
                true-color = true;
                auto-format = true;
                end-of-line-diagnostics = "hint";
                inline-diagnostics.cursor-line = "warning";
                cursor-shape = {
                  insert = "bar";
                  normal = "block";
                  select = "underline";
                };
                indent-guides.render = true;
                lsp.display-inlay-hints = true;
                file-picker.hidden = false;
              };
            };
            # Helix picks most servers from its defaults; these are the ones that differ.
            languages = {
              language-server.nixd.command = "nixd";
              language-server.basedpyright = {
                command = "basedpyright-langserver";
                args = [ "--stdio" ];
              };
              language = [
                {
                  name = "nix";
                  language-servers = [ "nixd" ];
                  formatter.command = "nixfmt";
                  auto-format = true;
                }
                {
                  name = "python";
                  language-servers = [
                    "basedpyright"
                    "ruff"
                  ];
                  auto-format = true;
                }
                {
                  name = "bash";
                  formatter = {
                    command = "shfmt";
                    args = [
                      "-i"
                      "2"
                    ];
                  };
                }
              ];
            };
          };

          programs.zed-editor = {
            enable = true;
            extraPackages = tools;
            extensions = [
              "nix"
              "svelte"
              "qml"
              "kdl"
              "html"
              "toml"
            ];
            userSettings = {
              helix_mode = true;
              # The wallpaper's palette, copied into Zed's themes folder by theme.nix.
              theme = {
                mode = "dark";
                dark = "Cosmos";
                light = "Cosmos";
              };
              relative_line_numbers = "enabled";
              format_on_save = "on";
              inlay_hints.enabled = true;
              # nixpkgs keeps Zed up to date, and nothing leaves for Zed's servers.
              auto_update = false;
              telemetry = {
                diagnostics = false;
                metrics = false;
              };
              # Zed's own Node download doesn't run on NixOS; npm-based servers use nixpkgs' node.
              node = {
                path = lib.getExe pkgs.nodejs;
                npm_path = lib.getExe' pkgs.nodejs "npm";
              };
              # Servers from PATH (tools above), not downloads.
              lsp = lib.genAttrs [ "rust-analyzer" "nixd" "basedpyright" "ruff" ] (_: {
                binary.path_lookup = true;
              });
              languages = {
                Nix = {
                  language_servers = [
                    "nixd"
                    "!nil"
                  ];
                  formatter.external = {
                    command = "nixfmt";
                    arguments = [ ];
                  };
                };
                Python.language_servers = [
                  "basedpyright"
                  "ruff"
                  "!pyright"
                  "!pylsp"
                ];
              };

              # The assistant runs on nabu's models over NetBird; nothing goes to a cloud provider.
              # Edit predictions would need Zed's servers, so they're off.
              language_models.openai_compatible.nabu = {
                api_url = "http://nabu.netbird.cloud:8080/v1";
                available_models = [
                  {
                    name = "main";
                    display_name = "nabu main";
                    # Its 256k context is shared by two slots.
                    max_tokens = 131072;
                  }
                  {
                    name = "helper";
                    display_name = "nabu helper (vision)";
                    max_tokens = 96000;
                    capabilities.images = true;
                  }
                ];
              };
              agent.default_model = {
                provider = "nabu";
                model = "main";
              };
              edit_predictions.provider = "none";
            };
          };

          # Zed wants a key for every provider; llama-swap checks none, and Hermes sends "local" too.
          # In the systemd environment as well, for Zed started from the launcher.
          home.sessionVariables.NABU_API_KEY = "local";
          systemd.user.sessionVariables.NABU_API_KEY = "local";
        }
      )
    ];
  };
}
