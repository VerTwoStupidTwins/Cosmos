# Evaluation checks for Odin's model-swapping service, not GPU inference.
{ pkgs, odin }:
let
  inherit (pkgs) lib;
  swap = odin.services.llama-swap;
  models = swap.settings.models or { };
  gemma = models.gemma4-balanced-q4 or { };
  embedding = models.embeddinggemma2 or { };
  clef = models.clef-flash-q8 or { };
  clefCommand = clef.cmd or "";
  clefPath = "/var/lib/llama-models/clef-flash-8aa35d1cc7e1/Clef-Flash-Q8_0.gguf";
  hasClefArgument =
    flag: value:
    lib.hasInfix (builtins.unsafeDiscardStringContext " ${
       lib.escapeShellArgs [
         flag
         value
       ]
     } ") " ${clefCommand} ";
  embeddingCommand = embedding.cmd or "";
  hasEmbeddingArgument =
    flag: value:
    # Regex patterns cannot carry a derivation context; keep it on the command.
    lib.hasInfix (builtins.unsafeDiscardStringContext " ${
       lib.escapeShellArgs [
         flag
         value
       ]
     } ") " ${embeddingCommand} ";
  command = gemma.cmd or "";
  group = swap.settings.routing.router.settings.groups.rx-7900xt or { };
  proxyUnit = odin.systemd.services.llama-swap;
  provision = odin.systemd.services.odin-inference-models or { };
  gemmaRoot = "/var/lib/llama-models/gemma4-hauhau-balanced-mtp-f9093662a2e7";
  modelPath = "${gemmaRoot}/Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-Q4_K_M.gguf";
  projectorPath = "${gemmaRoot}/mmproj-Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-BF16.gguf";
  draftPath = "${gemmaRoot}/mtp-gemma-4-26B-A4B-it.gguf";
  hasArgument =
    flag: value:
    lib.hasInfix (builtins.unsafeDiscardStringContext " ${
       lib.escapeShellArgs [
         flag
         value
       ]
     } ") " ${command} ";
  checks = {
    embeddingPinnedRuntime =
      let
        runtime = odin.services.llama-cpp-instances.intel.package;
      in
      runtime.version == "4fbc76dec51d0add466f0210855c0596589b60d4"
      && runtime.outputs == [ "out" ]
      && runtime.preConfigure == ""
      && runtime.syclPreemptionMode == 3
      && builtins.elem (lib.cmakeBool "GGML_SYCL_F16" true) runtime.cmakeFlags
      && !(builtins.elem (lib.cmakeBool "GGML_SYCL_F16" false) runtime.cmakeFlags)
      && builtins.all (flag: builtins.elem flag runtime.hardeningDisable) [
        "fortify"
        "fortify3"
      ]
      && runtime.pname == "llama-cpp-b50-sycl-fp16"
      && lib.hasPrefix "${lib.escapeShellArg (lib.getExe' runtime "llama-server")} " embeddingCommand
      && lib.hasPrefix "${lib.escapeShellArg (lib.getExe' runtime "llama-server")} " clefCommand;
    clefTestedBaseline =
      builtins.all (pair: hasClefArgument (builtins.elemAt pair 0) (builtins.elemAt pair 1)) [
        [
          "--host"
          "127.0.0.1"
        ]
        [
          "--port"
          "\${PORT}"
        ]
        [
          "--alias"
          "\${MODEL_ID}"
        ]
        [
          "--model"
          clefPath
        ]
        [
          "--device"
          "SYCL0"
        ]
        [
          "--n-gpu-layers"
          "99"
        ]
        [
          "--fit"
          "off"
        ]
        [
          "--ctx-size"
          "4096"
        ]
        [
          "--parallel"
          "1"
        ]
        [
          "--batch-size"
          "4096"
        ]
        [
          "--ubatch-size"
          "4096"
        ]
        [
          "--threads"
          "4"
        ]
        [
          "--threads-batch"
          "4"
        ]
        [
          "--cache-type-k"
          "f32"
        ]
        [
          "--cache-type-v"
          "f32"
        ]
        [
          "--flash-attn"
          "off"
        ]
        [
          "--sleep-idle-seconds"
          "-1"
        ]
      ]
      && builtins.all (flag: lib.hasInfix " ${lib.escapeShellArg flag} " " ${clefCommand} ") [
        "--slots"
        "--metrics"
      ]
      && !(lib.hasInfix "/home/" clefCommand)
      && !(lib.hasInfix "--mmproj" clefCommand);
    clefManagedDecision =
      (clef.proxy or "") == "http://127.0.0.1:\${PORT}"
      && (clef.useModelName or "") == "\${MODEL_ID}"
      && (clef.checkEndpoint or "") == "/health"
      && (clef.ttl or (-1)) == 0
      && (clef.timeouts.responseHeader or 0) == 1800
      && (clef.env or [ ]) == (embedding.env or [ ])
      && builtins.elem "ONEDNN_DEFAULT_FPMATH_MODE=STRICT" (clef.env or [ ])
      && builtins.elem "DNNL_DEFAULT_FPMATH_MODE=STRICT" (clef.env or [ ])
      && lib.hasInfix "unvalidated" (clef.description or "");
    embeddingManagedProxy =
      (embedding.proxy or "") == "http://127.0.0.1:\${PORT}"
      && (embedding.useModelName or "") == "\${MODEL_ID}"
      && (embedding.checkEndpoint or "") == "/health"
      && (embedding.timeouts.responseHeader or 0) == 1800
      && lib.hasInfix "unvalidated" (embedding.description or "")
      && !(builtins.any (entry: lib.hasPrefix "VK_DRIVER_FILES=" entry) (embedding.env or [ ]));
    embeddingConservativeBaseline =
      builtins.all (pair: hasEmbeddingArgument (builtins.elemAt pair 0) (builtins.elemAt pair 1)) [
        [
          "--device"
          "SYCL0"
        ]
        [
          "--mmproj-device"
          "SYCL0"
        ]
        [
          "--n-gpu-layers"
          "99"
        ]
        [
          "--fit"
          "off"
        ]
        [
          "--pooling"
          "mean"
        ]
        [
          "--ctx-size"
          "8192"
        ]
        [
          "--parallel"
          "1"
        ]
        [
          "--batch-size"
          "8192"
        ]
        [
          "--ubatch-size"
          "8192"
        ]
        [
          "--threads"
          "4"
        ]
        [
          "--threads-batch"
          "4"
        ]
        [
          "--cache-type-k"
          "f32"
        ]
        [
          "--cache-type-v"
          "f32"
        ]
        [
          "--flash-attn"
          "off"
        ]
        [
          "--video-ffmpeg-dir"
          "${pkgs.ffmpeg}/bin"
        ]
        [
          "--sleep-idle-seconds"
          "-1"
        ]
        [
          "--model"
          "/var/lib/llama-models/embeddinggemma2-031f0d4b3553/embeddinggemma-2-Q8_0.gguf"
        ]
        [
          "--mmproj"
          "/var/lib/llama-models/embeddinggemma2-031f0d4b3553/mmproj-BF16.gguf"
        ]
        [
          "--host"
          "127.0.0.1"
        ]
        [
          "--port"
          "\${PORT}"
        ]
        [
          "--alias"
          "\${MODEL_ID}"
        ]
      ]
      && builtins.all (flag: lib.hasInfix " ${lib.escapeShellArg flag} " " ${embeddingCommand} ") [
        "--embedding"
        "--mmproj-offload"
        "--slots"
        "--metrics"
      ]
      && !(lib.hasInfix "/home/" embeddingCommand)
      && !(lib.hasInfix "--image-max-tokens" embeddingCommand)
      && !(lib.hasInfix "--video-fps" embeddingCommand)
      && (embedding.ttl or (-1)) == 0
      && builtins.elem "ONEDNN_DEFAULT_FPMATH_MODE=STRICT" (embedding.env or [ ])
      && builtins.elem "DNNL_DEFAULT_FPMATH_MODE=STRICT" (embedding.env or [ ]);
    b50ResidentGroup =
      let
        b50 = swap.settings.routing.router.settings.groups.intel-b50 or { };
      in
      (b50.members or [ ]) == [
        "embeddinggemma2"
        "clef-flash-q8"
      ]
      && !(b50.swap or true)
      && !(b50.exclusive or true)
      && (b50.persistent or false)
      &&
        (swap.settings.hooks.on_startup.preload or [ ]) == [
          "embeddinggemma2"
          "clef-flash-q8"
        ]
      && !(swap.settings ? preload);
    provisionBeforeProxy =
      builtins.elem "odin-inference-models.service" proxyUnit.requires
      && builtins.elem "odin-inference-models.service" proxyUnit.after
      && (provision.serviceConfig.Type or "") == "oneshot";
    exactModelRoster =
      builtins.attrNames models == [
        "clef-flash-q8"
        "embeddinggemma2"
        "gemma4-balanced-q4"
      ];
    gemma128kAndBatch =
      hasArgument "--ctx-size" "131072"
      && hasArgument "--parallel" "1"
      && hasArgument "--batch-size" "512"
      && hasArgument "--ubatch-size" "256"
      && hasArgument "--threads" "12"
      && hasArgument "--threads-batch" "12";
    gemmaNativeMtp =
      hasArgument "--spec-type" "draft-mtp"
      && hasArgument "--model-draft" draftPath
      && hasArgument "--spec-draft-n-max" "3"
      && hasArgument "--device-draft" "Vulkan0"
      && hasArgument "--spec-draft-ngl" "99"
      && hasArgument "--flash-attn" "on";
    gemmaQ8Caches = builtins.all (flag: hasArgument flag "q8_0") [
      "--cache-type-k"
      "--cache-type-v"
      "--cache-type-k-draft"
      "--cache-type-v-draft"
    ];
    gemmaSampling =
      hasArgument "--temp" "0.6"
      && hasArgument "--top-k" "64"
      && hasArgument "--top-p" "0.9"
      && hasArgument "--min-p" "0.05"
      && hasArgument "--repeat-penalty" "1.1";
    gemmaThinking =
      lib.hasInfix "--jinja" command
      && hasArgument "--chat-template-kwargs" (builtins.toJSON { enable_thinking = true; })
      && !(lib.hasInfix "--reasoning-format" command);
    gemmaGpuVision =
      hasArgument "--mmproj" projectorPath
      && hasArgument "--mmproj-device" "Vulkan0"
      && lib.hasInfix "--mmproj-offload" command
      && !(lib.hasInfix "--no-mmproj-offload" command);
    gemmaPromptCache =
      hasArgument "--cache-ram" "8192"
      && lib.hasInfix "--cache-prompt" command
      && lib.hasInfix "--cache-idle-slots" command
      && !(lib.hasInfix "--slot-prompt-similarity" command)
      && !(lib.hasInfix "--cache-reuse" command);
    gemmaTestedResidency =
      hasArgument "--load-mode" "mmap"
      && hasArgument "--fit" "off"
      && hasArgument "--gpu-layers" "99"
      && !(builtins.any (flag: lib.hasInfix flag command) [
        "cpu-moe"
        "mlock"
        "--lazy-mode"
        "--sleep-idle-seconds"
        "--no-kv-unified"
      ])
      && (gemma.ttl or (-1)) == 0;
    gemmaManagedBackend =
      hasArgument "--model" modelPath
      && !(lib.hasInfix "/home/" command)
      && hasArgument "--host" "127.0.0.1"
      && hasArgument "--port" "\${PORT}"
      && hasArgument "--alias" "\${MODEL_ID}"
      && (gemma.proxy or "") == "http://127.0.0.1:\${PORT}"
      && (gemma.useModelName or "") == "\${MODEL_ID}"
      && (gemma.checkEndpoint or "") == "/health"
      && (gemma.timeouts.responseHeader or 0) == 1800
      && swap.settings.startPort == 18081;
    gemmaRuntime =
      lib.hasPrefix "${lib.escapeShellArg (lib.getExe' odin.services.llama-cpp-instances.amd.package "llama-server")} " command
      && odin.services.llama-cpp-instances.amd.package.version == "0.6.0";
    scopedVulkan =
      hasArgument "--device" "Vulkan0"
      && builtins.any (
        entry: lib.hasPrefix "VK_DRIVER_FILES=" entry && lib.hasSuffix "/radeon_icd.x86_64.json" entry
      ) (gemma.env or [ ])
      && !(builtins.any (
        entry: lib.hasPrefix "ONEAPI_DEVICE_SELECTOR=" entry || lib.hasPrefix "ForcePreemptionMode=" entry
      ) (gemma.env or [ ]));
    honestValidationLabel =
      lib.hasInfix "125879" (gemma.description or "")
      && lib.hasInfix "256 image tokens" (gemma.description or "")
      && lib.hasInfix "0.223 GiB" (gemma.description or "")
      && lib.hasInfix "unvalidated" (gemma.description or "");
    netbirdOnlyFrontend =
      let
        firewall = odin.networking.firewall;
        allowsPort =
          rules:
          builtins.elem swap.port rules.allowedTCPPorts
          || builtins.any (
            range: range.from <= swap.port && swap.port <= range.to
          ) rules.allowedTCPPortRanges;
      in
      swap.listenAddress == "0.0.0.0"
      && swap.port == 8081
      && !swap.openFirewall
      && firewall.enable
      && !(allowsPort firewall)
      && builtins.elem swap.port (firewall.interfaces.wt0.allowedTCPPorts or [ ])
      && builtins.all (name: name == "wt0" || !(allowsPort firewall.interfaces.${name})) (
        builtins.attrNames firewall.interfaces
      )
      && builtins.all (name: name == "lo") firewall.trustedInterfaces;
    gpuSpecificSwapGroup =
      (swap.settings.routing.router.use or "") == "group"
      &&
        builtins.attrNames (swap.settings.routing.router.settings.groups or { }) == [
          "intel-b50"
          "rx-7900xt"
        ]
      && (group.members or [ ]) == [ "gemma4-balanced-q4" ]
      && (group.swap or false)
      && !(group.exclusive or true)
      && (group.persistent or false)
      && !(swap.settings ? groups)
      && !(swap.settings ? matrix)
      && builtins.attrNames (swap.settings.hooks or { }) == [ "on_startup" ];
    noPayloadCapture = swap.settings.captureBuffer == 0;
    gpuSandbox =
      proxyUnit.serviceConfig.ProtectHome
      && proxyUnit.serviceConfig.DynamicUser
      && proxyUnit.serviceConfig.DevicePolicy == "closed"
      &&
        proxyUnit.serviceConfig.DeviceAllow == [
          "/dev/dri/by-path/pci-0000:0d:00.0-render rw"
          "/dev/dri/by-path/pci-0000:10:00.0-render rw"
        ]
      && !proxyUnit.serviceConfig.MemoryDenyWriteExecute
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
  # Assert against the real config above, but do not realise GPU toolchains just
  # to serialize test fixtures. Production units/config retain their contexts.
  fixtureSettings = builtins.fromJSON (
    builtins.unsafeDiscardStringContext (builtins.toJSON swap.settings)
  );
  settingsJson = pkgs.writeText "odin-llama-swap-settings.json" (builtins.toJSON fixtureSettings);
  settingsYaml = (pkgs.formats.yaml { }).generate "odin-llama-swap.yaml" fixtureSettings;
  proxyService = pkgs.writeTextDir "llama-swap.service" (
    builtins.unsafeDiscardStringContext odin.systemd.units."llama-swap.service".text
  );
  provisionService = pkgs.writeTextDir "odin-inference-models.service" (
    builtins.unsafeDiscardStringContext odin.systemd.units."odin-inference-models.service".text
  );
  unitVerifier = pkgs.writeShellScript "verify-odin-llama-swap-units" ''
    # Keep the unit's executable available without pulling its GPU backend config.
    test -x ${lib.getExe swap.package}
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
    ${pkgs.gnugrep}/bin/grep -F -- '3c13133469e431312fffb8b1d9c85ae42199e6bb5746ea1da84e8ddf2097d73c' ${provision.serviceConfig.ExecStart}
    ${pkgs.gnugrep}/bin/grep -F -- '${modelPath}' ${provision.serviceConfig.ExecStart}
    ${pkgs.gnugrep}/bin/grep -F -- 'b5346e5bfd906f5e16878c2d0b8243e948ca7410fa28ea35be9b0c54a0ac10b7' ${provision.serviceConfig.ExecStart}
    ${pkgs.gnugrep}/bin/grep -F -- '${projectorPath}' ${provision.serviceConfig.ExecStart}
    ${pkgs.gnugrep}/bin/grep -F -- '62bd3af7f66c9308de9a5454233852f8c7324c93767e8dfb824ed45b9179864a' ${provision.serviceConfig.ExecStart}
    ${pkgs.gnugrep}/bin/grep -F -- '${draftPath}' ${provision.serviceConfig.ExecStart}
    ${pkgs.gnugrep}/bin/grep -F -- '87a232aa1f7495cfc90ce22f08bb3779655e1b05c991c84b21afa4c1c8c4e0f5' ${provision.serviceConfig.ExecStart}
    ${pkgs.gnugrep}/bin/grep -F -- '${clefPath}' ${provision.serviceConfig.ExecStart}
    ${pkgs.gnugrep}/bin/grep -F -- '6f1bd4ac6c5df7444f9cca7ca36cafe6cfa34cd6f49fefb1e0b4be8143aed8bc' ${provision.serviceConfig.ExecStart}
    ${pkgs.gnugrep}/bin/grep -F -- '995aaa56e88b9b631f651861d659b728a625ccc02a238be37cff56cf11dc0032' ${provision.serviceConfig.ExecStart}
    ${pkgs.gnugrep}/bin/grep -F -- '/var/lib/llama-models/embeddinggemma2-031f0d4b3553/embeddinggemma-2-Q8_0.gguf' ${provision.serviceConfig.ExecStart}
    ${pkgs.gnugrep}/bin/grep -F -- '/var/lib/llama-models/embeddinggemma2-031f0d4b3553/mmproj-BF16.gguf' ${provision.serviceConfig.ExecStart}
    if ${pkgs.gnugrep}/bin/grep -E -- 'lfm25-heretic|qwen|swift15|UNVERIFIED' ${provision.serviceConfig.ExecStart}; then
      printf 'Retired artifacts must not block Gemma provisioning\n' >&2
      exit 1
    fi
    ${pkgs.python3}/bin/python - ${settingsJson} <<'PY'
  import json, shlex, sys
  with open(sys.argv[1]) as f:
      command = json.load(f)['models']['gemma4-balanced-q4']['cmd']
  flags = [arg for arg in shlex.split(command)[1:] if arg.startswith('--')]
  assert len(flags) == len(set(flags)), 'duplicate backend flag could override tested settings'
  PY
    mkdir -p "$out/bin"
    cp ${proxyService}/llama-swap.service ${provisionService}/odin-inference-models.service "$out/"
    cp ${unitVerifier} "$out/bin/verify-units"
    cp ${provision.serviceConfig.ExecStart} "$out/provision-models.sh"
    cp ${settingsJson} "$out/settings.json"
    cp ${settingsYaml} "$out/settings.yaml"
    printf '%s\n' '${builtins.toJSON checks}' > "$out/checks.json"
''
