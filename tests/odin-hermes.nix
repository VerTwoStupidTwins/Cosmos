# Fresh Odin-only deployment; runtime activation is verified separately.
{
  pkgs,
  odin,
  thoth,
  argus,
}:
let
  inherit (pkgs) lib;
  egressRules = lib.last (
    lib.splitString " " odin.systemd.services.cosmos-hermes-egress.serviceConfig.ExecStart
  );
  checks = {
    correctAgentSchema =
      (odin.services.hermes-agent.settings.agent.image_input_mode or "auto") == "native";
    explicitSurfaceTools =
      builtins.all
        (
          surface:
          builtins.elem "kanban" (odin.services.hermes-agent.settings.platform_toolsets.${surface} or [ ])
          && !(builtins.elem "hermes-cli" (
            odin.services.hermes-agent.settings.platform_toolsets.${surface} or [ ]
          ))
        )
        [
          "cli"
          "tui"
          "api_server"
          "cron"
          "telegram"
          "discord"
        ];
    singleDurableWorker = (odin.services.hermes-agent.settings.kanban.max_in_progress or 0) == 1;
    enabledOnOdin = odin.services.hermes-agent.enable or false;
    dashboardEnabled = (odin.services.hermes-agent.backend.mode or "none") == "dashboard";
    dashboardSandboxed =
      (odin.systemd.services.hermes-backend.serviceConfig.ProtectHome or false) == "tmpfs";
    otherHostsUnchanged =
      !(thoth.services.hermes-agent.enable or false) && !(argus.services.hermes-agent.enable or false);
    nativeNonAdmin =
      !(odin.services.hermes-agent.container.enable or true)
      && !(builtins.elem "wheel" odin.users.users.hermes.extraGroups)
      && !(builtins.elem "docker" odin.users.users.hermes.extraGroups)
      && odin.systemd.services.hermes-agent.serviceConfig.NoNewPrivileges;
    privateHomes = odin.systemd.services.hermes-agent.serviceConfig.ProtectHome == "tmpfs";
    noGlobalProfile = !(odin.services.hermes-agent.addToSystemPackages or true);
    localEndpoint = odin.services.hermes-agent.settings.model.base_url == "http://127.0.0.1:18090/v1";
    noFallback = odin.services.hermes-agent.settings.fallback_providers == [ ];
    explicitMessaging =
      odin.services.hermes-agent.settings.platforms.telegram.enabled
      && odin.services.hermes-agent.settings.platforms.discord.enabled
      && odin.services.hermes-agent.settings.unauthorized_dm_behavior == "ignore"
      && odin.services.hermes-agent.environment.GATEWAY_ALLOW_ALL_USERS == "false"
      && odin.services.hermes-agent.environment.TELEGRAM_ALLOW_ALL_USERS == "false"
      && odin.services.hermes-agent.environment.DISCORD_ALLOW_ALL_USERS == "false";
    noImplicitVoiceUpload = !odin.services.hermes-agent.settings.stt.enabled;
    dnsStubConfigurationVisible =
      !(builtins.elem "-/run/systemd/resolve" odin.systemd.services.hermes-agent.serviceConfig.InaccessiblePaths)
      && builtins.elem "-/run/systemd/resolve/io.systemd.Resolve" odin.systemd.services.hermes-agent.serviceConfig.InaccessiblePaths;
    noManagedModelEngine = !odin.services.hermes-agent.settings.local_runtime.enabled;
    autonomousWithinBoundary =
      odin.services.hermes-agent.settings.approvals.mode == "off"
      && !odin.services.hermes-agent.settings.memory.write_approval
      && !odin.services.hermes-agent.settings.skills.write_approval;
    requiredBoundary = builtins.elem "cosmos-hermes-egress.service" odin.systemd.services.hermes-agent.requires;
    noRawDevices = odin.systemd.services.hermes-agent.serviceConfig.PrivateDevices;
    noOperatorKeys = builtins.elem "/run/secrets" odin.systemd.services.hermes-agent.serviceConfig.InaccessiblePaths;
    dashboardSecretRootOnly =
      odin.sops.secrets.hermes-dashboard-env.owner == "root"
      && odin.sops.secrets.hermes-dashboard-env.group == "root"
      && odin.sops.secrets.hermes-dashboard-env.mode == "0400"
      && odin.sops.secrets.hermes-dashboard-env.key == "hermes_dashboard_env";
    dashboardNetBirdOnly =
      odin.services.hermes-agent.backend.waitFor == "interface"
      && odin.services.hermes-agent.backend.interfaceName == "wt0"
      && builtins.elem 9119 odin.networking.firewall.interfaces.wt0.allowedTCPPorts
      && !(builtins.elem 9119 odin.networking.firewall.allowedTCPPorts);
    noNixBuilderProxy =
      odin.nix.settings.allowed-users == [
        "root"
        "@wheel"
      ];
    namespaceGuard = odin.systemd.services.hermes-agent.serviceConfig.RestrictNamespaces or false;
    interfaceDiscoveryAllowed = builtins.elem "AF_NETLINK" odin.systemd.services.hermes-backend.serviceConfig.RestrictAddressFamilies;
    noUserManagerEscape =
      !odin.users.users.hermes.linger
      && !(builtins.elem "/run/user" (
        odin.systemd.services.hermes-agent.serviceConfig.BindReadOnlyPaths or [ ]
      ));
    fixedOwnerRpc = (odin.services.hermes-agent.environment.HERMES_LOCAL_OWNER_PORT or "") == "18092";
    managedHomeCompatibility = odin.services.hermes-agent.package ? managedSource;
    safeStateProvisioner =
      !odin.users.users.hermes.createHome
      && odin.systemd.services.hermes-state-setup.serviceConfig.Type == "oneshot"
      && builtins.elem "hermes-state-setup.service" odin.systemd.services.hermes-agent.requires;
    setupPreservesSetgid =
      odin.systemd.services.hermes-state-setup.serviceConfig.Group == odin.services.hermes-agent.group
      && !(builtins.elem "CAP_FSETID" odin.systemd.services.hermes-state-setup.serviceConfig.CapabilityBoundingSet);
    rootNeverSwitchesIdentity =
      builtins.all
        (
          cap:
          !(builtins.elem cap odin.systemd.services.hermes-state-setup.serviceConfig.CapabilityBoundingSet)
        )
        [
          "CAP_SETUID"
          "CAP_SETGID"
        ];
    serviceUserPreparation =
      builtins.all
        (
          name:
          let
            service = odin.systemd.services.${name}.serviceConfig;
          in
          service.User == odin.services.hermes-agent.user
          && !(service.PermissionsStartOnly or false)
          && builtins.any (
            command:
            lib.hasInfix "--prepare-data" command
            && !(lib.hasPrefix "+" command)
            && !(lib.hasPrefix "!" command)
          ) (service.ExecStartPre or [ ])
        )
        [
          "hermes-agent"
          "hermes-backend"
        ];
    tuiBootstrapConfigured =
      (odin.services.hermes-agent.package ? runtimeSource)
      &&
        builtins.all
          (
            name:
            (odin.systemd.services.${name}.environment.HERMES_PYTHON_SRC_ROOT or "")
            == toString odin.services.hermes-agent.package.runtimeSource
          )
          [
            "hermes-agent"
            "hermes-backend"
          ];
    noRootCapability =
      odin.systemd.services.hermes-agent.serviceConfig.CapabilityBoundingSet == ""
      && odin.systemd.services.hermes-backend.serviceConfig.CapabilityBoundingSet == "";
  };
  failures = builtins.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
assert lib.assertMsg (failures == [ ]) (
  "Odin Hermes checks failed: " + lib.concatStringsSep ", " failures
);
pkgs.runCommand "odin-hermes-check"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.yq-go
      pkgs.jq
    ];
  }
  ''
    mkdir -p fixture/packages fixture/tests fixture/modules/features/agents
    mkdir -p "$TMPDIR/home/.cache/cosmos-specialist-tests"
    export HOME="$TMPDIR/home"
    export HERMES_TEST_SOURCE=${odin.services.hermes-agent.package.managedSource}
    # Execute the file lookup/import path used by the Node TUI, not only the CLI.
    TUI_BOOTSTRAP=${odin.services.hermes-agent.package.runtimeSource}/ui-tui/scripts/gateway_bootstrap.py
    test -f "$TUI_BOOTSTRAP"
    test ! -L "$TUI_BOOTSTRAP"
    python3 -c 'import runpy,sys; m=runpy.run_path(sys.argv[1],run_name="tui_bootstrap_check"); assert callable(m["bootstrap"]); import hermes_cli.gateway_runtime_discovery as d; assert hasattr(d,"_root_managed_home")' "$TUI_BOOTSTRAP"
    cp ${../packages/hermes-state-setup.py} fixture/packages/hermes-state-setup.py
    cp ${../modules/features/agents/hermes-local.nix} fixture/modules/features/agents/hermes-local.nix
    cp ${./hermes-state-setup.py} fixture/tests/hermes-state-setup.py
    cp ${./hermes-managed-home.py} fixture/tests/hermes-managed-home.py
    cp ${./hermes-owner-port.py} fixture/tests/hermes-owner-port.py
    # Nix's build sandbox rejects chmod(S_ISGID), even for disposable files.
    # Execute the full lifecycle syscall fixtures separately as the Odin operator.
    python3 fixture/tests/hermes-state-setup.py NativeModuleTests
    python3 fixture/tests/hermes-managed-home.py
    python3 fixture/tests/hermes-owner-port.py
    cp ${../packages/hermes-inference-gateway.py} fixture/packages/hermes-inference-gateway.py
    cp ${../packages/hermes-dashboard-bootstrap.py} fixture/packages/hermes-dashboard-bootstrap.py
    cp ${./hermes-inference-gateway.py} fixture/tests/hermes-inference-gateway.py
    cp ${./hermes-dashboard-bootstrap.py} fixture/tests/hermes-dashboard-bootstrap.py
    python3 fixture/tests/hermes-inference-gateway.py
    python3 fixture/tests/hermes-dashboard-bootstrap.py
    python3 - ${lib.escapeShellArg egressRules} <<'PY'
    import pathlib, sys
    rules = pathlib.Path(sys.argv[1]).read_text()
    wanted = 'meta skuid "hermes" meta mark 0x1bd00 oifname "enp4s0" fib daddr type != local udp sport 58120 counter accept'
    assert wanted in rules, 'Missing narrowly scoped kernel WireGuard transport exception'
    assert rules.index(wanted) < rules.index('meta skuid "hermes" counter reject')
    PY
    yq -o=json ${../secrets.yaml} | jq -e '.hermes_dashboard_env | startswith("ENC[")' >/dev/null
    mkdir -p "$out"
    printf '%s\n' '${builtins.toJSON checks}' > "$out/checks.json"
  ''
