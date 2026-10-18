# Independent native llama.cpp instances; backend packages remain host choices.
{ config, ... }:
{
  flake.modules.nixos."llama-cpp-instances" =
    {
      config,
      lib,
      pkgs,
      utils,
      ...
    }:
    let
      inherit (lib) mkOption types;
      cfg = config.services.llama-cpp-instances;
      validName = name: builtins.match "[A-Za-z0-9][A-Za-z0-9_-]*" name != null;
      instances = lib.filterAttrs (name: _: validName name) cfg;
      enabled = lib.filterAttrs (_: instance: instance.enable) instances;
      ports = map (instance: instance.port) (builtins.attrValues enabled);
      scalar = types.oneOf [
        types.str
        types.bool
        types.int
        types.float
      ];
      argumentsFor =
        instance:
        lib.cli.toCommandLine
          (key: {
            option =
              if lib.hasPrefix "-" key then
                key
              else if builtins.stringLength key > 1 then
                "--${key}"
              else
                "-${key}";
            sep = null;
            explicitBool = false;
            formatArg = lib.generators.mkValueStringDefault { };
          })
          (
            instance.settings
            // {
              inherit (instance) host port model;
            }
          );
      launcher =
        name: instance:
        pkgs.writeShellScriptBin "llama-server-${name}" ''
          exec ${pkgs.coreutils}/bin/env -- ${
            lib.escapeShellArgs (lib.mapAttrsToList (key: value: "${key}=${value}") instance.environment)
          } ${lib.getExe' instance.package "llama-server"} ${lib.escapeShellArgs (argumentsFor instance)} "$@"
        '';
    in
    {
      options.services.llama-cpp-instances = mkOption {
        default = { };
        description = "Named llama.cpp servers with independent packages, devices, and state.";
        type = types.attrsOf (
          types.submodule {
            options = {
              enable = lib.mkEnableOption "this llama.cpp server";
              package = lib.mkPackageOption pkgs "llama-cpp" { };
              host = mkOption {
                type = types.str;
                default = "127.0.0.1";
                description = "Listen address; no network exposure is enabled by default.";
              };
              port = mkOption {
                type = types.port;
                default = 8080;
                description = "TCP port, unique among enabled instances.";
              };
              model = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Absolute runtime GGUF filename, not an imported Nix path. Required when enabled.";
              };
              settings = mkOption {
                type = types.attrsOf (
                  types.oneOf [
                    scalar
                    (types.listOf scalar)
                  ]
                );
                default = { };
                description = "Additional CLI options; host, port, and model use their dedicated options.";
              };
              environment = mkOption {
                type = types.attrsOf types.str;
                default = { };
                description = "Non-secret environment applied only to this instance and its named CLI launcher.";
              };
              renderDevice = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Optional absolute render-node path (including a stable PCI by-path symlink) for device isolation.";
              };
              allowJit = mkOption {
                type = types.bool;
                default = false;
                description = "Allow executable writable memory when required by a backend such as Intel oneDNN.";
              };
              openFirewall = mkOption {
                type = types.bool;
                default = false;
                description = "Explicitly open this instance's TCP port when enabled.";
              };
            };
          }
        );
      };

      config = {
        assertions = [
          {
            assertion = builtins.length ports == builtins.length (lib.unique ports);
            message = "llama-cpp-instances: enabled instances must have distinct TCP ports.";
          }
        ]
        ++ lib.concatLists (
          lib.mapAttrsToList (name: instance: [
            {
              assertion = validName name;
              message = "llama-cpp-instances: names must contain only letters, digits, underscores, or hyphens and start with a letter or digit.";
            }
            {
              assertion = !instance.enable || (instance.model != null && lib.hasPrefix "/" instance.model);
              message = "llama-cpp-instances.${name}: an enabled instance needs an absolute model filename.";
            }
            {
              assertion = instance.renderDevice == null || lib.hasPrefix "/dev/dri/" instance.renderDevice;
              message = "llama-cpp-instances.${name}: renderDevice must be a path under /dev/dri/.";
            }
            {
              assertion = builtins.all (
                key: key != "LLAMA_CACHE" && builtins.match "[A-Za-z_][A-Za-z0-9_]*" key != null
              ) (builtins.attrNames instance.environment);
              message = "llama-cpp-instances.${name}: environment keys must be valid variable names; LLAMA_CACHE is reserved for the isolated service cache.";
            }
            {
              assertion = builtins.all (
                key:
                !(builtins.elem key [
                  "host"
                  "--host"
                  "port"
                  "--port"
                  "model"
                  "--model"
                  "m"
                  "-m"
                ])
              ) (builtins.attrNames instance.settings);
              message = "llama-cpp-instances.${name}: use the dedicated host, port, and model options, not settings aliases.";
            }
          ]) cfg
        );

        # Distinct names avoid PATH collisions between backend packages. These
        # tools remain available for diagnostics even while servers are disabled.
        environment.systemPackages = lib.mapAttrsToList launcher instances;
        networking.firewall.allowedTCPPorts = map (instance: instance.port) (
          builtins.attrValues (lib.filterAttrs (_: instance: instance.openFirewall) enabled)
        );
        systemd.services = lib.mapAttrs' (
          name: instance:
          let
            id = "llama-cpp-${name}";
            arguments = argumentsFor instance;
          in
          lib.nameValuePair id {
            description = "llama.cpp server (${name})";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" ];
            environment = instance.environment // {
              LLAMA_CACHE = "/var/cache/${id}";
            };
            serviceConfig = {
              ExecStart = utils.escapeSystemdExecArgs (
                [ (lib.getExe' instance.package "llama-server") ] ++ arguments
              );
              Restart = "on-failure";
              RestartSec = 30;
              DynamicUser = true;
              SupplementaryGroups = [ "render" ];
              StateDirectory = id;
              CacheDirectory = id;
              StateDirectoryMode = "0750";
              CacheDirectoryMode = "0750";
              WorkingDirectory = "/var/lib/${id}";
              NoNewPrivileges = true;
              CapabilityBoundingSet = "";
              PrivateTmp = true;
              PrivateDevices = false;
              ProtectSystem = "strict";
              ProtectHome = true;
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectKernelLogs = true;
              ProtectControlGroups = true;
              RestrictSUIDSGID = true;
              LockPersonality = true;
              MemoryDenyWriteExecute = !instance.allowJit;
              RestrictAddressFamilies = [
                "AF_INET"
                "AF_INET6"
                "AF_UNIX"
              ];
              SystemCallArchitectures = "native";
              SystemCallFilter = [
                "@system-service"
                "~@privileged"
              ];
            }
            // lib.optionalAttrs (instance.renderDevice != null) {
              DevicePolicy = "closed";
              DeviceAllow = [ "${instance.renderDevice} rw" ];
            };
          }
        ) enabled;
      };
    };

  perSystem = { pkgs, ... }: {
    checks.llama-cpp-instances = import ../../../tests/llama-cpp-instances.nix {
      inherit pkgs;
      module = config.flake.modules.nixos."llama-cpp-instances";
    };
  };
}
