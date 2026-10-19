# Evaluation checks for Odin's model-swapping service, not GPU inference.
{ pkgs, odin }:
let
  inherit (pkgs) lib;
  swap = odin.services.llama-swap;
  models = swap.settings.models or { };
  proxyUnit = odin.systemd.services.llama-swap;
  provision = odin.systemd.services.odin-inference-models or { };
  checks = {
    provisionBeforeProxy =
      builtins.elem "odin-inference-models.service" proxyUnit.requires
      && builtins.elem "odin-inference-models.service" proxyUnit.after
      && (provision.serviceConfig.Type or "") == "oneshot";
    exactTestingRoster =
      builtins.attrNames models == [
        "lfm25-heretic-q4"
        "qwen36-apex-balanced-unverified"
      ];
    loopbackOnly =
      swap.listenAddress == "127.0.0.1"
      && swap.port == 8081
      && !swap.openFirewall
      && !(builtins.elem 8081 odin.networking.firewall.allowedTCPPorts);
    explicitExperimentalLabels =
      lib.hasInfix "UNVERIFIED" models.qwen36-apex-balanced-unverified.name
      && lib.hasInfix "publisher SHA-256" models.qwen36-apex-balanced-unverified.description
      && lib.hasInfix "retrieval failed" models.lfm25-heretic-q4.description;
    twoIndependentLfmContexts =
      lib.hasInfix "--ctx-size 262144" models.lfm25-heretic-q4.cmd
      && lib.hasInfix "--parallel 2" models.lfm25-heretic-q4.cmd;
    twoIndependentQwenContexts =
      lib.hasInfix "--ctx-size 65536" models.qwen36-apex-balanced-unverified.cmd
      && lib.hasInfix "--parallel 2" models.qwen36-apex-balanced-unverified.cmd;
    scopedVulkan = builtins.all (
      model:
      lib.hasInfix "--device Vulkan0" model.cmd
      && builtins.any (
        entry: lib.hasPrefix "VK_DRIVER_FILES=" entry && lib.hasSuffix "/radeon_icd.x86_64.json" entry
      ) model.env
      && !(builtins.any (
        entry: lib.hasPrefix "ONEAPI_DEVICE_SELECTOR=" entry || lib.hasPrefix "ForcePreemptionMode=" entry
      ) model.env)
    ) (builtins.attrValues models);
    runtimePaths = builtins.all (
      model: lib.hasInfix "/var/lib/llama-models/" model.cmd && !(lib.hasInfix "/home/" model.cmd)
    ) (builtins.attrValues models);
    exclusiveResidency =
      !(swap.settings ? groups) && !(swap.settings ? matrix) && !(swap.settings ? hooks);
    noPayloadCapture = swap.settings.captureBuffer == 0;
    gpuSandbox =
      proxyUnit.serviceConfig.ProtectHome
      && proxyUnit.serviceConfig.DynamicUser
      && proxyUnit.serviceConfig.DevicePolicy == "closed"
      && proxyUnit.serviceConfig.DeviceAllow == [ "/dev/dri/by-path/pci-0000:0d:00.0-render rw" ]
      && builtins.elem "render" proxyUnit.serviceConfig.SupplementaryGroups
      && proxyUnit.serviceConfig.KillMode == "control-group";
    rootProvisioningIsOffline =
      provision.serviceConfig.PrivateNetwork
      && provision.serviceConfig.ProtectHome == "read-only"
      && provision.serviceConfig.ReadWritePaths == [ "/var/lib/llama-models" ];
    routerEnabled = odin.services.llama-swap.enable;
    noCompetingStandaloneServers =
      !odin.services.llama-cpp.enable
      && !odin.services.llama-cpp-instances.amd.enable
      && !odin.services.llama-cpp-instances.intel.enable;
  };
  failures = builtins.attrNames (lib.filterAttrs (_: result: !result) checks);
  settingsJson = pkgs.writeText "odin-llama-swap-settings.json" (builtins.toJSON swap.settings);
  settingsYaml = (pkgs.formats.yaml { }).generate "odin-llama-swap.yaml" swap.settings;
  proxyService = odin.systemd.units."llama-swap.service".unit;
  provisionService = odin.systemd.units."odin-inference-models.service".unit;
  unitVerifier = pkgs.writeShellScript "verify-odin-llama-swap-units" ''
    export SYSTEMD_LOG_TARGET=console
    export SYSTEMD_UNIT_PATH=${pkgs.systemd}/example/systemd/system
    exec ${pkgs.systemd}/bin/systemd-analyze verify --man=no \
      ${proxyService}/llama-swap.service ${provisionService}/odin-inference-models.service
  '';
in
assert lib.assertMsg (failures == [ ]) (
  "Odin llama-swap checks failed: " + lib.concatStringsSep ", " failures
);
pkgs.runCommand "odin-llama-swap-check" { } ''
  ${pkgs.bash}/bin/bash -n ${provision.serviceConfig.ExecStart}
  mkdir -p "$out/bin"
  cp ${proxyService}/llama-swap.service ${provisionService}/odin-inference-models.service "$out/"
  cp ${unitVerifier} "$out/bin/verify-units"
  cp ${provision.serviceConfig.ExecStart} "$out/provision-models.sh"
  cp ${settingsJson} "$out/settings.json"
  cp ${settingsYaml} "$out/settings.yaml"
  printf '%s\n' '${builtins.toJSON checks}' > "$out/checks.json"
''
