# Evaluation checks for Odin's model-swapping service, not GPU inference.
{ pkgs, odin }:
let
  inherit (pkgs) lib;
  swap = odin.services.llama-swap;
  models = swap.settings.models or { };
  qwen = models.barozp-reap-q6 or { };
  swift = models.swift15-iq3s or { };
  swiftCommand = swift.cmd or "";
  command = qwen.cmd or "";
  group = swap.settings.routing.router.settings.groups.rx-7900xt or { };
  proxyUnit = odin.systemd.services.llama-swap;
  provision = odin.systemd.services.odin-inference-models or { };
  modelPath = "/var/lib/llama-models/qwen36-reap-opus-mtp-f11f37b9ad21/Qwen3.6-29B-REAP-Opus-Reasoning-Distill-MTP-Q6_K.gguf";
  swiftPath = "/var/lib/llama-models/swift15-qwen38-27b-gsq-rco-d74895bbe5db/Swift-1.5-Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf";
  hasSwiftArgument =
    flag: value:
    lib.hasInfix " ${
       lib.escapeShellArgs [
         flag
         value
       ]
     } " " ${swiftCommand} ";
  hasArgument =
    flag: value:
    lib.hasInfix (lib.escapeShellArgs [
      flag
      value
    ]) command;
  checks = {
    provisionBeforeProxy =
      builtins.elem "odin-inference-models.service" proxyUnit.requires
      && builtins.elem "odin-inference-models.service" proxyUnit.after
      && (provision.serviceConfig.Type or "") == "oneshot";
    exactRadeonRoster =
      builtins.attrNames models == [
        "barozp-reap-q6"
        "swift15-iq3s"
      ];
    swift128kAndBatch =
      builtins.all (pair: hasSwiftArgument (builtins.elemAt pair 0) (builtins.elemAt pair 1)) [
        [
          "--ctx-size"
          "131072"
        ]
        [
          "--parallel"
          "1"
        ]
        [
          "--threads"
          "12"
        ]
        [
          "--threads-batch"
          "12"
        ]
        [
          "--batch-size"
          "1024"
        ]
        [
          "--ubatch-size"
          "256"
        ]
      ]
      && lib.hasInfix "--no-kv-unified" swiftCommand;
    swiftDenseVulkan =
      hasSwiftArgument "--device" "Vulkan0"
      && hasSwiftArgument "--gpu-layers" "99"
      && hasSwiftArgument "--fit" "off"
      && (swift.env or [ ]) == qwen.env
      && !(lib.hasInfix "cpu-moe" swiftCommand);
    swiftMappedNotLocked =
      hasSwiftArgument "--load-mode" "mmap"
      && hasSwiftArgument "--lazy-mode" "off"
      && hasSwiftArgument "--sleep-idle-seconds" "-1"
      && !(lib.hasInfix "mlock" swiftCommand);
    swiftMtpAndQ8 =
      hasSwiftArgument "--spec-type" "draft-mtp"
      && hasSwiftArgument "--spec-draft-n-max" "3"
      && hasSwiftArgument "--spec-draft-n-min" "0"
      && hasSwiftArgument "--spec-draft-p-min" "0"
      && hasSwiftArgument "--flash-attn" "on"
      && builtins.all (flag: hasSwiftArgument flag "q8_0") [
        "--cache-type-k"
        "--cache-type-v"
        "--cache-type-k-draft"
        "--cache-type-v-draft"
      ];
    swiftPromptReuse =
      hasSwiftArgument "--slot-prompt-similarity" "0.9"
      && hasSwiftArgument "--cache-ram" "32768"
      && lib.hasInfix "--cache-prompt" swiftCommand
      && lib.hasInfix "--cache-idle-slots" swiftCommand
      && !(lib.hasInfix "--cache-reuse" swiftCommand)
      && !(lib.hasInfix "--ctx-checkpoints" swiftCommand)
      && !(lib.hasInfix "--checkpoint-min-step" swiftCommand);
    swiftSamplingAndReasoning =
      hasSwiftArgument "--temp" "1.0"
      && hasSwiftArgument "--top-p" "0.95"
      && hasSwiftArgument "--top-k" "20"
      && hasSwiftArgument "--min-p" "0.0"
      && hasSwiftArgument "--presence-penalty" "0.0"
      && hasSwiftArgument "--repeat-penalty" "1.0"
      && hasSwiftArgument "--reasoning-format" "deepseek"
      && builtins.all (flag: lib.hasInfix flag swiftCommand) [
        "--jinja"
        "--metrics"
        "--slots"
      ]
      && !(lib.hasInfix "--reasoning-effort" swiftCommand);
    swiftManagedRuntime =
      hasSwiftArgument "--model" swiftPath
      && !(lib.hasInfix "/home/" swiftCommand)
      && hasSwiftArgument "--host" "127.0.0.1"
      && hasSwiftArgument "--port" "\${PORT}"
      && hasSwiftArgument "--alias" "\${MODEL_ID}"
      && (swift.proxy or "") == "http://127.0.0.1:\${PORT}"
      && (swift.useModelName or "") == "\${MODEL_ID}"
      && (swift.checkEndpoint or "") == "/health"
      && (swift.ttl or (-1)) == 0
      && (swift.timeouts.responseHeader or 0) == 1800;
    swiftValidationLabel =
      lib.hasInfix "IQ3_S" (swift.name or "")
      && lib.hasInfix "129994" (swift.description or "")
      && lib.hasInfix "unvalidated" (swift.description or "");
    loopbackOnly =
      swap.listenAddress == "127.0.0.1"
      && swap.port == 8081
      && !swap.openFirewall
      && !(builtins.elem 8081 odin.networking.firewall.allowedTCPPorts);
    honestValidationLabel =
      lib.hasInfix "Q6_K" (qwen.name or "")
      && lib.hasInfix "64K" (qwen.description or "")
      && lib.hasInfix "128K" (qwen.description or "");
    single128kContext =
      hasArgument "--ctx-size" "131072"
      && hasArgument "--parallel" "1"
      && lib.hasInfix "--no-kv-unified" command;
    expertPlacement =
      hasArgument "--gpu-layers" "99"
      && hasArgument "--n-cpu-moe" "11"
      && hasArgument "--spec-draft-n-cpu-moe" "11"
      && hasArgument "--fit" "off";
    lockedResidentWeights =
      hasArgument "--load-mode" "mmap+mlock"
      && hasArgument "--lazy-mode" "off"
      && hasArgument "--sleep-idle-seconds" "-1"
      && (proxyUnit.serviceConfig.LimitMEMLOCK or "") == "infinity"
      && (qwen.ttl or (-1)) == 0;
    tunedBatchAndThreads =
      hasArgument "--threads" "12"
      && hasArgument "--threads-batch" "12"
      && hasArgument "--batch-size" "1024"
      && hasArgument "--ubatch-size" "256";
    q8MainAndDraftCaches = builtins.all (flag: hasArgument flag "q8_0") [
      "--cache-type-k"
      "--cache-type-v"
      "--cache-type-k-draft"
      "--cache-type-v-draft"
    ];
    nativeMtp =
      hasArgument "--flash-attn" "on"
      && hasArgument "--spec-type" "draft-mtp"
      && hasArgument "--spec-draft-n-max" "3"
      && hasArgument "--spec-draft-n-min" "0"
      && hasArgument "--spec-draft-p-min" "0";
    ramPromptCache =
      lib.hasInfix "--cache-prompt" command
      && hasArgument "--cache-ram" "32768"
      && lib.hasInfix "--cache-idle-slots" command
      && !(lib.hasInfix "--cache-reuse" command);
    reasoningAndSampling =
      lib.hasInfix "--jinja" command
      && hasArgument "--reasoning-format" "deepseek"
      && hasArgument "--temp" "0.6"
      && hasArgument "--top-p" "0.95"
      && hasArgument "--top-k" "20"
      && lib.hasInfix "--metrics" command
      && lib.hasInfix "--slots" command;
    managedLoopbackBackend =
      hasArgument "--host" "127.0.0.1"
      && hasArgument "--port" "\${PORT}"
      && hasArgument "--alias" "\${MODEL_ID}"
      && (qwen.proxy or "") == "http://127.0.0.1:\${PORT}"
      && (qwen.useModelName or "") == "\${MODEL_ID}"
      && (qwen.checkEndpoint or "") == "/health"
      && swap.settings.startPort == 18081;
    longPromptTimeout = (qwen.timeouts.responseHeader or 0) == 1800;
    scopedVulkan =
      hasArgument "--device" "Vulkan0"
      && builtins.any (
        entry: lib.hasPrefix "VK_DRIVER_FILES=" entry && lib.hasSuffix "/radeon_icd.x86_64.json" entry
      ) (qwen.env or [ ])
      && !(builtins.any (
        entry: lib.hasPrefix "ONEAPI_DEVICE_SELECTOR=" entry || lib.hasPrefix "ForcePreemptionMode=" entry
      ) (qwen.env or [ ]));
    runtimePaths = hasArgument "--model" modelPath && !(lib.hasInfix "/home/" command);
    gpuSpecificSwapGroup =
      (swap.settings.routing.router.use or "") == "group"
      && builtins.attrNames (swap.settings.routing.router.settings.groups or { }) == [ "rx-7900xt" ]
      &&
        (group.members or [ ]) == [
          "barozp-reap-q6"
          "swift15-iq3s"
        ]
      && (group.swap or false)
      && !(group.exclusive or true)
      && (group.persistent or false)
      && !(swap.settings ? groups)
      && !(swap.settings ? matrix)
      && !(swap.settings ? hooks);
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
  ${pkgs.gnugrep}/bin/grep -F -- '27b6c065ff4ba02d76dc11116ecebb78b4bc38aaa27637414c8008ba000db4ae' ${provision.serviceConfig.ExecStart}
  ${pkgs.gnugrep}/bin/grep -F -- '${modelPath}' ${provision.serviceConfig.ExecStart}
  ${pkgs.gnugrep}/bin/grep -F -- '9aecf1cd41b2cb2f32a74e0d889e33855ebef43b26f43b43feb5720239e677e5' ${provision.serviceConfig.ExecStart}
  ${pkgs.gnugrep}/bin/grep -F -- '${swiftPath}' ${provision.serviceConfig.ExecStart}
  if ${pkgs.gnugrep}/bin/grep -E -- 'lfm25-heretic|qwen36-apex|UNVERIFIED' ${provision.serviceConfig.ExecStart}; then
    printf 'Retired artifacts must not block Qwen provisioning\n' >&2
    exit 1
  fi
  mkdir -p "$out/bin"
  cp ${proxyService}/llama-swap.service ${provisionService}/odin-inference-models.service "$out/"
  cp ${unitVerifier} "$out/bin/verify-units"
  cp ${provision.serviceConfig.ExecStart} "$out/provision-models.sh"
  cp ${settingsJson} "$out/settings.json"
  cp ${settingsYaml} "$out/settings.yaml"
  printf '%s\n' '${builtins.toJSON checks}' > "$out/checks.json"
''
