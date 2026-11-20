# modules/llama/core.nix
#
# What every llama.cpp backend module shares. Each backend (nixos.llama-cuda, -rocm, -sycl, -vulkan) builds
# llama.cpp for its compute stack and registers it under llama.backends.<name>, with the environment its programs
# need. This module puts a wrapper for each backend's tools on the PATH, such as llama-server-cuda and
# llama-bench-vulkan, and services that run llama.cpp take the package and environment from llama.backends.
{ inputs, ... }:
{
  flake.modules.nixos.llama =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.llama;

      # Wrapped for each backend, as llama-<tool>-<backend>.
      tools = [
        "server"
        "bench"
        "cli"
      ];

      wrapper =
        name: backend: tool:
        pkgs.writeShellScriptBin "llama-${tool}-${name}" ''
          ${lib.concatStrings (
            lib.mapAttrsToList (variable: value: ''
              export ${variable}=${lib.escapeShellArg value}
            '') backend.env
          )}
          exec ${lib.getExe' backend.package "llama-${tool}"} "$@"
        '';
    in
    {
      # Loaded once however many backend modules import it.
      key = "cosmos#llama";

      options.llama = {
        src = lib.mkOption {
          type = lib.types.path;
          default = inputs.llama-cpp;
          defaultText = lib.literalExpression "inputs.llama-cpp";
          description = "The llama.cpp source every backend builds from, so they all run the same version.";
        };

        version = lib.mkOption {
          type = lib.types.str;
          default = "0-unstable-${inputs.llama-cpp.shortRev}";
          defaultText = lib.literalExpression ''"0-unstable-''${inputs.llama-cpp.shortRev}"'';
          description = "The version the backends' packages carry.";
        };

        packages = lib.mkOption {
          type = lib.types.attrs;
          readOnly = true;
          description = "The llama.cpp flake's package scope on this host's nixpkgs, which the backends build from.";
        };

        backends = lib.mkOption {
          default = { };
          description = "The llama.cpp builds on this host, one per compute backend.";
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                package = lib.mkOption {
                  type = lib.types.package;
                  description = "llama.cpp built for this backend.";
                };

                env = lib.mkOption {
                  type = lib.types.attrsOf lib.types.str;
                  default = { };
                  description = "Environment variables its programs need.";
                };

                devicePrefix = lib.mkOption {
                  type = lib.types.str;
                  example = "CUDA";
                  description = ''
                    What llama.cpp calls this backend's devices, numbered from 0 (CUDA0, CUDA1). `--list-devices`
                    shows them.
                  '';
                };
              };
            }
          );
        };
      };

      config = {
        # Called on this host's nixpkgs, so CUDA and ROCm builds follow its configuration. The backends build without
        # the web UI (useWebUi = false, webui = null): services talk to the API, and its build broke upstream on
        # 2026-11-14, when it started importing a module the Nix build doesn't fetch.
        llama.packages = pkgs.callPackage "${cfg.src}/.devops/nix/scope.nix" {
          llamaVersion = cfg.version;
        };

        environment.systemPackages = lib.concatLists (
          lib.mapAttrsToList (name: backend: map (wrapper name backend) tools) cfg.backends
        );
      };
    };
}
