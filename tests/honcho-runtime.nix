# Configuration and synthetic helper checks; live service acceptance is separate.
{ pkgs, odin }:
let
  inherit (pkgs) lib;
  containers = odin.virtualisation.oci-containers.containers;
  api = containers.honcho-api or { };
  worker = containers.honcho-worker or { };
  common =
    container:
    (container.podman.user or "root") == "honcho"
    && (container.pull or "missing") == "never"
    && (container.user or "") == "100:101"
    && (container.imageFile or null) != null
    && (container.networks or [ ]) == [ "host" ]
    && (container.ports or [ ]) == [ ]
    && (container.devices or [ ]) == [ ]
    && !(container.privileged or true)
    && builtins.elem "--read-only" (container.extraOptions or [ ])
    && builtins.elem "--security-opt=no-new-privileges" (container.extraOptions or [ ])
    && (container.environment.AUTH_USE_AUTH or "false") == "true"
    && !(container.environment ? AUTH_JWT_SECRET)
    && !(container.environment ? DB_CONNECTION_URI)
    && (container.log-driver or "journald") == "k8s-file";
  checks = {
    rootlessApi = common api;
    rootlessWorker = common worker;
    stableNativeIdentity = odin.users.users.honcho.uid == 992;
    workerAfterReadyApi =
      builtins.elem "honcho-api" (worker.dependsOn or [ ])
      && (api.podman.sdnotify or "conmon") == "conmon"
      && (odin.systemd.services.podman-honcho-api.serviceConfig.ExecStartPost or [ ]) != [ ]
      && !(builtins.any (flag: lib.hasPrefix "--health-" flag) (api.extraOptions or [ ]));
    namespaceSafeServerEnvironment =
      builtins.all
        (
          name:
          let
            container = containers.${name};
            unit = odin.systemd.services."podman-${name}".serviceConfig;
          in
          container.environmentFiles == [ ]
          && builtins.elem "--env=AUTH_JWT_SECRET" container.extraOptions
          && (unit.EnvironmentFile or [ ]) == [ "/var/lib/cosmos-honcho/server.env" ]
          && (unit.LoadCredential or [ ]) == [ ]
        )
        [
          "honcho-api"
          "honcho-worker"
        ];
    privateCredentials =
      (odin.systemd.services.honcho-credentials.serviceConfig.StateDirectoryMode or "") == "0700"
      && builtins.elem "honcho-credentials.service" (
        odin.systemd.services.podman-honcho-api.requires or [ ]
      );
    enforcedNetwork =
      builtins.elem "cosmos-honcho-egress.service" (
        odin.systemd.services.podman-honcho-api.requires or [ ]
      )
      && builtins.elem "cosmos-honcho-egress.service" (
        odin.systemd.services.podman-honcho-worker.requires or [ ]
      );
    privateOperatorHomesWithUsableRootlessRuntime =
      !(odin.systemd.services.podman-honcho-api.serviceConfig.ProtectHome or true)
      && builtins.elem "/home" (
        odin.systemd.services.podman-honcho-api.serviceConfig.InaccessiblePaths or [ ]
      )
      && (odin.systemd.services.podman-honcho-api.environment.XDG_RUNTIME_DIR or "") == "/run/user/992";
    noNewHermesAuthority =
      !odin.users.users.hermes.linger
      && !(builtins.elem "honcho" odin.users.users.hermes.extraGroups)
      && !(builtins.elem "wheel" odin.users.users.hermes.extraGroups);
    noCloudFallbacks =
      builtins.all
        (
          name:
          let
            model = builtins.fromJSON (api.environment.${name} or "{}");
          in
          (model.model or "") == "gemma4-balanced-q4"
          && (model.fallback or "absent") == null
          && (model.overrides.base_url or "") == "http://127.0.0.1:18094/v1"
        )
        [
          "DERIVER_MODEL_CONFIG"
          "SUMMARY_MODEL_CONFIG"
          "DREAM_DEDUCTION_MODEL_CONFIG"
          "DREAM_INDUCTION_MODEL_CONFIG"
        ];
    matchingEmbeddings =
      (api.environment.EMBEDDING_VECTOR_DIMENSIONS or "") == "768"
      &&
        ((builtins.fromJSON (api.environment.EMBEDDING_MODEL_CONFIG or "{}")).model or "")
        == "embeddinggemma2";
  };
  failures = builtins.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
assert lib.assertMsg (
  failures == [ ]
) "Honcho runtime checks failed: ${lib.concatStringsSep ", " failures}";
pkgs.runCommand "honcho-runtime-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  export PYTHONDONTWRITEBYTECODE=1
  python ${./honcho-credentials.py} ${../packages/honcho-credentials.py}
  python ${./honcho-inference.py} ${../packages/hermes-inference-gateway.py} ${../packages/honcho-inference-gateway.py}
  python ${./honcho-entrypoint.py} ${../packages/honcho-entrypoint.py}
  python ${./honcho-ready.py} ${../packages/honcho-ready.py}
  mkdir "$out"
  printf '%s\n' 'Honcho rootless runtime, local models, credentials and isolation checks passed' > "$out/result"
''
