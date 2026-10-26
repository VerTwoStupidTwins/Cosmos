# Declarative contract; real-image HTTP acceptance is a separate disposable test.
{
  pkgs,
  odin,
  thoth,
  argus,
}:
let
  inherit (pkgs) lib;
  container = odin.virtualisation.oci-containers.containers.openconcho or { };
  unit = odin.systemd.services.podman-openconcho or { };
  egressRules = lib.last (
    lib.splitString " " odin.systemd.services.cosmos-openconcho-egress.serviceConfig.ExecStart
  );
  checks = {
    pinnedRootlessImage =
      (container.podman.user or "") == "openconcho"
      && (container.user or "") == "101:101"
      && (container.pull or "") == "never"
      && (container.imageFile or null) != null
      && !(container.privileged or true)
      && (container.devices or [ ]) == [ ]
      && builtins.elem "--cap-drop=ALL" (container.extraOptions or [ ])
      && builtins.elem "--read-only" (container.extraOptions or [ ]);
    namespaceSafeCredentials =
      (unit.serviceConfig.EnvironmentFile or [ ]) == [ "/var/lib/cosmos-openconcho/container.env" ]
      && (container.environmentFiles or [ ]) == [ ]
      && !((container.environment or { }) ? OPENCONCHO_API_TOKEN)
      && builtins.elem "--env=OPENCONCHO_API_TOKEN" (container.extraOptions or [ ])
      && !(lib.any (v: lib.hasInfix "signing.key" v || lib.hasInfix "/run/postgresql" v) (
        container.volumes or [ ]
      ));
    independentIdentity =
      (odin.users.users.openconcho.uid or null) == 991
      && (odin.users.users.openconcho.extraGroups or [ ]) == [ ]
      && !(builtins.elem "openconcho" odin.users.users.hermes.extraGroups);
    netbirdOnly =
      (odin.services.openconcho.listenAddress or "") == "100.94.82.252"
      && builtins.elem 9120 odin.networking.firewall.interfaces.wt0.allowedTCPPorts
      && !(builtins.elem 9120 odin.networking.firewall.allowedTCPPorts)
      && builtins.elem "cosmos-openconcho-egress.service" (unit.requires or [ ]);
    privateRootProvisioning =
      (odin.systemd.services.openconcho-credentials.serviceConfig.User or "") == "root"
      && (odin.systemd.services.openconcho-credentials.serviceConfig.StateDirectoryMode or "") == "0700";
    otherHostsUnchanged =
      !(thoth.virtualisation.oci-containers.containers ? openconcho)
      && !(argus.virtualisation.oci-containers.containers ? openconcho);
  };
  failures = builtins.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
assert lib.assertMsg (
  failures == [ ]
) "OpenConcho checks failed: ${lib.concatStringsSep ", " failures}";
pkgs.runCommand "openconcho-check"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.apacheHttpd
    ];
  }
  ''
    export PYTHONDONTWRITEBYTECODE=1
    python ${./openconcho-credentials.py} ${../packages/openconcho-credentials.py} ${../packages/honcho-credentials.py} ${pkgs.apacheHttpd}/bin/htpasswd
    ${pkgs.runtimeShell} -n ${../packages/openconcho-start.sh}
    python - ${lib.escapeShellArg egressRules} <<'PY'
    import pathlib, sys
    rules = pathlib.Path(sys.argv[1]).read_text()
    wanted = 'meta skuid "openconcho" meta mark 0x1bd00 oifname "enp4s0" fib daddr type != local udp sport 58120 counter accept'
    assert wanted in rules, 'Missing dual-stack kernel WireGuard transport exception'
    assert rules.index(wanted) < rules.index('meta skuid "openconcho" counter reject')
    PY
    mkdir "$out"
    printf '%s\n' 'OpenConcho rootless configuration and private credentials passed' > "$out/result"
  ''
