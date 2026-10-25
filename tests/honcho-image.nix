# The archive is a Nix dependency; no Podman daemon or registry pull is needed.
{
  pkgs,
  odin,
  image ? null,
}:
let
  inherit (pkgs) lib;
  checks = {
    imageConfigured = image != null;
    imageRetainedBySystem =
      image != null && builtins.elem (toString image) (map toString odin.system.extraDependencies);
    runtimePolicyInstalled =
      odin.virtualisation.containers.enable && odin.environment.etc ? "containers/policy.json";
  };
  failures = builtins.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
assert lib.assertMsg (
  failures == [ ]
) "Honcho image prerequisites failed: ${lib.concatStringsSep ", " failures}";
pkgs.runCommand "honcho-image-check"
  {
    nativeBuildInputs = [
      pkgs.skopeo
      pkgs.jq
      pkgs.python3
    ];
  }
  ''
    set -euo pipefail
    mkdir "$out"
    # Nix already verified the archive hash. Inspect only; never start a server.
    skopeo --insecure-policy inspect docker-archive:${image} > "$TMPDIR/image.json"
    jq -e '.Architecture == "amd64" and .Os == "linux"' "$TMPDIR/image.json" >/dev/null
    python - ${image} ${odin.environment.etc."containers/policy.json".source} <<'PY'
    import json, sys, tarfile, tomllib
    with open(sys.argv[2]) as f:
        policy = json.load(f)
    assert isinstance(policy.get('default'), list) and policy['default']
    with tarfile.open(sys.argv[1]) as archive:
        manifest = json.load(archive.extractfile('manifest.json'))
        assert len(manifest) == 1
        assert manifest[0]['RepoTags'] == ['ghcr.io/plastic-labs/honcho:3.4.0']
        version = None
        for layer in manifest[0]['Layers']:
            with tarfile.open(fileobj=archive.extractfile(layer), mode='r|*') as contents:
                for entry in contents:
                    if entry.name.lstrip('./') == 'app/pyproject.toml' and entry.isfile():
                        version = tomllib.load(contents.extractfile(entry))['project']['version']
        assert version == '3.4.0', f'Unexpected packaged application version: {version}'
    PY
    printf '%s\n' 'Honcho 3.4.0 Linux amd64 archive, application version and generated runtime policy verified' > "$out/result"
  ''
