# Verify the packaged provider, not a mutable runtime plugin installation.
{ pkgs, odin }:
let
  inherit (pkgs) lib;
  cfg = odin.services.hermes-agent;
  inherit (cfg) package;
  checks = {
    selectedProvider = (cfg.settings.memory.provider or "") == "honcho";
    packagedSdk = package ? honchoSdk;
    privateClient = (cfg.privateHomeFiles."honcho.json" or "") == "/var/lib/cosmos-honcho/client.json";
    credentialsOrdered = builtins.elem "honcho-credentials.service" odin.systemd.services.hermes-state-setup.requires;
    noContainerPrivilege =
      !odin.users.users.hermes.linger
      && !(builtins.elem "honcho" odin.users.users.hermes.extraGroups)
      && !(builtins.elem "wheel" odin.users.users.hermes.extraGroups);
  };
  failures = builtins.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
assert lib.assertMsg (
  failures == [ ]
) "Hermes Honcho integration failed: ${lib.concatStringsSep ", " failures}";
pkgs.runCommand "hermes-honcho-check" { } ''
  export PYTHONDONTWRITEBYTECODE=1
  ${pkgs.python3}/bin/python3 ${./hermes-private-files.py} ${../packages/hermes-state-setup.py}
  export HERMES_HOME="$TMPDIR/hermes"
  mkdir -p "$HERMES_HOME"
  export PYTHONPATH=${package.honchoSdk}/${package.python.sitePackages}
  ${package.hermesVenv}/bin/python - <<'PY'
  import importlib.metadata as metadata
  from pathlib import Path
  from packaging.requirements import Requirement
  from plugins.memory import find_provider_dir
  import honcho
  assert metadata.version('honcho-ai') == '2.2.0'
  for item in metadata.requires('honcho-ai') or []:
      requirement = Requirement(item)
      if requirement.marker is None or requirement.marker.evaluate({'extra': ""}):
          assert requirement.specifier.contains(metadata.version(requirement.name)), requirement.name
  provider = find_provider_dir('honcho')
  assert provider is not None and '/plugins/memory/honcho' in str(provider)
  assert str(provider).startswith('/nix/store/')
  assert (Path(provider) / '__init__.py').is_file()
  import json, os
  from plugins.memory import load_memory_provider
  (Path(os.environ['HERMES_HOME']) / 'honcho.json').write_text(json.dumps({
      'baseUrl': 'http://127.0.0.1:8000', 'apiKey': 'public-offline-fixture',
      'hosts': {'hermes': {'enabled': True, 'workspace': 'personal', 'peerName': 'public-fixture'}},
  }))
  loaded = load_memory_provider('honcho', register_skills=False)
  assert loaded is not None and loaded.name == 'honcho'
  PY
  mkdir "$out"
  printf '%s\n' 'Pinned official Honcho provider and SDK match the sealed Hermes runtime' > "$out/result"
''
