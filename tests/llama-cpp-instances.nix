# Evaluation and argument-transport tests, not simulated GPU inference.
{ pkgs, module }:
let
  inherit (pkgs) lib;
  fixture = pkgs.writeShellScriptBin "llama-server" ''
    printf '%s\n' "''${SELECTOR-}" "$@"
  '';
  base = {
    alpha = {
      enable = true;
      package = fixture;
      port = 9001;
      model = "/var/lib/models/model with % and $ signs.gguf";
      settings.device = "first";
      environment.SELECTOR = "intel";
      renderDevice = "/dev/dri/by-path/pci-test-alpha-render";
      allowJit = true;
    };
    beta = {
      enable = true;
      package = fixture;
      port = 9002;
      model = "/var/lib/models/second.gguf";
      settings.device = "second";
      environment.SELECTOR = "amd";
      renderDevice = "/dev/dri/by-path/pci-test-beta-render";
    };
  };
  evaluate =
    instances:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        module
        {
          nixpkgs.pkgs = pkgs;
          system.stateVersion = "26.05";
          services.llama-cpp-instances = instances;
        }
      ];
    }).config;
  violations =
    config:
    map (item: item.message) (
      builtins.filter (
        item: !item.assertion && lib.hasPrefix "llama-cpp-instances" item.message
      ) config.assertions
    );
  good = evaluate base;
  services = good.systemd.services;
  alpha = services.llama-cpp-alpha.serviceConfig;
  beta = services.llama-cpp-beta.serviceConfig;
  disabled = evaluate (
    lib.mapAttrs (
      _: instance:
      instance
      // {
        enable = false;
        model = null;
      }
    ) base
  );
  duplicate = evaluate (
    base
    // {
      beta = base.beta // {
        port = 9001;
      };
    }
  );
  missingModel = evaluate (
    base
    // {
      alpha = base.alpha // {
        model = null;
      };
    }
  );
  reserved = evaluate (
    base
    // {
      alpha = base.alpha // {
        settings = {
          "-m" = "/other.gguf";
        };
      };
    }
  );
  invalidName = evaluate { "bad/name" = base.alpha; };
  invalidEnv = evaluate (
    base
    // {
      alpha = base.alpha // {
        environment = {
          "BAD;KEY" = "ignored";
        };
      };
    }
  );
  cacheOverride = evaluate (
    base
    // {
      alpha = base.alpha // {
        environment.LLAMA_CACHE = "/shared";
      };
    }
  );
  firewall = evaluate (
    base
    // {
      beta = base.beta // {
        openFirewall = true;
      };
    }
  );
  checks = {
    valid = violations good == [ ];
    distinctUnits = services ? llama-cpp-alpha && services ? llama-cpp-beta;
    distinctState =
      alpha.StateDirectory == "llama-cpp-alpha" && beta.StateDirectory == "llama-cpp-beta";
    distinctCache =
      alpha.CacheDirectory != beta.CacheDirectory
      && services.llama-cpp-alpha.environment.LLAMA_CACHE == "/var/cache/llama-cpp-alpha"
      && services.llama-cpp-beta.environment.LLAMA_CACHE == "/var/cache/llama-cpp-beta";
    distinctEnvironment =
      services.llama-cpp-alpha.environment.SELECTOR == "intel"
      && services.llama-cpp-beta.environment.SELECTOR == "amd";
    isolatedDevices =
      alpha.DevicePolicy == "closed"
      && beta.DevicePolicy == "closed"
      && alpha.DeviceAllow == [ "/dev/dri/by-path/pci-test-alpha-render rw" ]
      && beta.DeviceAllow == [ "/dev/dri/by-path/pci-test-beta-render rw" ];
    scopedJit = !alpha.MemoryDenyWriteExecute && beta.MemoryDenyWriteExecute;
    argumentEscaping = lib.hasInfix "%% and $$ signs.gguf" alpha.ExecStart;
    noImplicitFirewall = good.networking.firewall.allowedTCPPorts == [ ];
    explicitFirewall = firewall.networking.firewall.allowedTCPPorts == [ 9002 ];
    disabledNoUnits =
      !(disabled.systemd.services ? llama-cpp-alpha) && !(disabled.systemd.services ? llama-cpp-beta);
    disabledValid = violations disabled == [ ];
    duplicateRejected = violations duplicate != [ ];
    missingModelRejected = violations missingModel != [ ];
    settingsAliasRejected = violations reserved != [ ];
    invalidNameRejected = violations invalidName != [ ];
    invalidEnvironmentRejected = violations invalidEnv != [ ];
    cacheOverrideRejected = violations cacheOverride != [ ];
  };
  failures = builtins.attrNames (lib.filterAttrs (_: result: !result) checks);
  alphaUnit = good.systemd.units."llama-cpp-alpha.service".unit;
  betaUnit = good.systemd.units."llama-cpp-beta.service".unit;
  unitVerifier = pkgs.writeShellScript "verify-llama-cpp-units" ''
    # systemd-analyze initializes /run before processing --root, so execute
    # this dry verification outside the Nix builder, never by starting units.
    export SYSTEMD_LOG_TARGET=console
    export SYSTEMD_UNIT_PATH=${pkgs.systemd}/example/systemd/system
    exec ${pkgs.systemd}/bin/systemd-analyze verify --man=no \
      ${alphaUnit}/llama-cpp-alpha.service ${betaUnit}/llama-cpp-beta.service
  '';
  launchers = good.environment.systemPackages;
  findLauncher =
    name: builtins.head (builtins.filter (p: (p.name or "") == "llama-server-${name}") launchers);
  expectedAlpha = pkgs.writeText "expected-alpha-arguments" ''
    intel
    --device
    first
    --host
    127.0.0.1
    --model
    /var/lib/models/model with % and $ signs.gguf
    --port
    9001
    --extra
    literal $argument
  '';
  expectedBeta = pkgs.writeText "expected-beta-arguments" ''
    amd
    --device
    second
    --host
    127.0.0.1
    --model
    /var/lib/models/second.gguf
    --port
    9002
  '';
in
assert lib.assertMsg (failures == [ ]) (
  "llama-cpp-instances checks failed: " + lib.concatStringsSep ", " failures
);
pkgs.runCommand "llama-cpp-instances-check" { } ''
  ${findLauncher "alpha"}/bin/llama-server-alpha --extra 'literal $argument' > alpha.args
  ${findLauncher "beta"}/bin/llama-server-beta > beta.args
  diff -u ${expectedAlpha} alpha.args
  diff -u ${expectedBeta} beta.args
  mkdir -p "$out/bin"
  cp alpha.args beta.args "$out/"
  cp ${alphaUnit}/llama-cpp-alpha.service ${betaUnit}/llama-cpp-beta.service "$out/"
  cp ${unitVerifier} "$out/bin/verify-units"
  printf '%s\n' '${builtins.toJSON checks}' > "$out/checks.json"
''
