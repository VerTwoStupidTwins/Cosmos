# Bootstrap checks use disposable keys and a fake op, never production identities.
{
  pkgs,
  odin,
  thoth,
  operatorIdentity ? null,
}:
let
  inherit (pkgs) lib;
  sops = odin.sops or null;
  checks = {
    sharedSecretFile =
      let
        odinFile = builtins.tryEval odin.sops.defaultSopsFile;
        thothFile = builtins.tryEval thoth.sops.defaultSopsFile;
      in
      odinFile.success
      && thothFile.success
      && odinFile.value == thothFile.value
      && odinFile.value == ../secrets.yaml;
    thothHostIdentity =
      (thoth.sops or null) != null
      && thoth.sops.age.sshKeyPaths == [ "/etc/ssh/ssh_host_ed25519_key" ]
      && thoth.sops.age.keyFile == null
      && !thoth.sops.age.generateKey
      && thoth.sops.gnupg.sshKeyPaths == [ ];
    operatorHelperConfigured = operatorIdentity != null;
    ageHostKey = sops != null && sops.age.sshKeyPaths == [ "/etc/ssh/ssh_host_ed25519_key" ];
    noGeneratedIdentity = sops != null && sops.age.keyFile == null && !sops.age.generateKey;
    noGpgIdentity = sops != null && sops.gnupg.sshKeyPaths == [ ];
    bootstrapProbesRootOnly =
      builtins.all
        (
          host:
          let
            probe = host.sops.secrets.bootstrap-validation or null;
          in
          probe != null
          && probe.owner == "root"
          && probe.group == "root"
          && probe.mode == "0400"
          && probe.key == "bootstrap_validation"
          && probe.format == "yaml"
          && probe.sopsFile == host.sops.defaultSopsFile
          && builtins.attrNames host.sops.secrets == [ "bootstrap-validation" ]
        )
        [
          odin
          thoth
        ];
  };
  failures = builtins.attrNames (lib.filterAttrs (_: passed: !passed) checks);
  fakeOp = pkgs.writeShellScriptBin "op" ''
    set -euo pipefail
    test "$#" -eq 2
    test "$1" = read
    test "$2" = 'op://fixture/Cosmos SOPS Operator/private key?ssh-format=openssh'
    test "''${FAIL_OP:-0}" != 1 || exit 17
    ${pkgs.coreutils}/bin/cat "$FIXTURE_SSH_KEY"
    test "''${FAIL_OP:-0}" != 2 || exit 17
  '';
in
assert lib.assertMsg (failures == [ ]) (
  "SOPS bootstrap checks failed: " + lib.concatStringsSep ", " failures
);
pkgs.runCommand "sops-bootstrap-check"
  {
    nativeBuildInputs = [
      pkgs.age
      pkgs.sops
      pkgs.ssh-to-age
      pkgs.openssh
      pkgs.jq
      pkgs.yq-go
    ];
  }
  ''
    set +x
    umask 077
    # Private fixture material exists only in this disposable build directory.
    unset SOPS_AGE_KEY SOPS_AGE_KEY_FILE
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    export XDG_CONFIG_HOME="$HOME/.config"
    ssh-keygen -q -t ed25519 -N "" -f "$TMPDIR/fixture-ssh"
    export FIXTURE_SSH_KEY="$TMPDIR/fixture-ssh"
    export COSMOS_SOPS_OPERATOR_KEY_REF='op://fixture/Cosmos SOPS Operator/private key?ssh-format=openssh'
    export SOPS_AGE_KEY_CMD=${operatorIdentity}/bin/cosmos-sops-identity
    export PATH=${fakeOp}/bin:"$PATH"
    recipient=$(ssh-to-age < "$FIXTURE_SSH_KEY.pub")
    printf '%s\n' '{"marker":"public-sops-roundtrip-fixture"}' > "$TMPDIR/plain.json"
    sops encrypt --age "$recipient" --input-type json --output-type json "$TMPDIR/plain.json" > "$TMPDIR/encrypted.json"
    sops decrypt --input-type json --output-type json "$TMPDIR/encrypted.json" | jq -e '.marker == "public-sops-roundtrip-fixture"' >/dev/null
    # Each authorized identity alone must decrypt; an unrelated one must fail.
    ssh-keygen -q -t ed25519 -N "" -f "$TMPDIR/second-ssh"
    second=$(ssh-to-age < "$TMPDIR/second-ssh.pub")
    ssh-to-age -private-key -i "$TMPDIR/second-ssh" > "$TMPDIR/second-age"
    ssh-keygen -q -t ed25519 -N "" -f "$TMPDIR/third-ssh"
    third=$(ssh-to-age < "$TMPDIR/third-ssh.pub")
    ssh-to-age -private-key -i "$TMPDIR/third-ssh" > "$TMPDIR/third-age"
    sops encrypt --age "$recipient,$second,$third" --input-type json --output-type json "$TMPDIR/plain.json" > "$TMPDIR/three-recipients.json"
    sops decrypt "$TMPDIR/three-recipients.json" | jq -e '.marker == "public-sops-roundtrip-fixture"' >/dev/null
    env -u SOPS_AGE_KEY_CMD SOPS_AGE_KEY_FILE="$TMPDIR/second-age" sops decrypt "$TMPDIR/three-recipients.json" | jq -e '.marker == "public-sops-roundtrip-fixture"' >/dev/null
    env -u SOPS_AGE_KEY_CMD SOPS_AGE_KEY_FILE="$TMPDIR/third-age" sops decrypt "$TMPDIR/three-recipients.json" | jq -e '.marker == "public-sops-roundtrip-fixture"' >/dev/null
    ssh-keygen -q -t ed25519 -N "" -f "$TMPDIR/unrelated-ssh"
    if FIXTURE_SSH_KEY="$TMPDIR/unrelated-ssh" sops decrypt "$TMPDIR/three-recipients.json" > "$TMPDIR/denied" 2>/dev/null; then
      echo 'Unrelated identity must not decrypt' >&2
      exit 1
    fi
    test ! -s "$TMPDIR/denied"
    printf '%s\n' 'set -x' > "$TMPDIR/enable-xtrace"
    BASH_ENV="$TMPDIR/enable-xtrace" ${operatorIdentity}/bin/cosmos-sops-identity > "$TMPDIR/trace-identity" 2> "$TMPDIR/trace-log"
    if grep -q 'AGE-SECRET-KEY-' "$TMPDIR/trace-log"; then
      echo 'Inherited shell tracing must not expose the operator identity' >&2
      exit 1
    fi
    if FAIL_OP=1 sops decrypt "$TMPDIR/encrypted.json" > "$TMPDIR/denied" 2>/dev/null; then
      echo '1Password failure must deny decryption' >&2
      exit 1
    fi
    test ! -s "$TMPDIR/denied"
    if COSMOS_SOPS_OPERATOR_KEY_REF= ${operatorIdentity}/bin/cosmos-sops-identity > "$TMPDIR/denied" 2>/dev/null; then
      echo 'Missing reference must deny identity retrieval' >&2
      exit 1
    fi
    test ! -s "$TMPDIR/denied"
    if COSMOS_SOPS_OPERATOR_KEY_REF='op://fixture/not-openssh' ${operatorIdentity}/bin/cosmos-sops-identity > "$TMPDIR/denied" 2>/dev/null; then
      echo 'Non-OpenSSH reference must be rejected' >&2
      exit 1
    fi
    test ! -s "$TMPDIR/denied"
    if FAIL_OP=2 ${operatorIdentity}/bin/cosmos-sops-identity > "$TMPDIR/partial-identity" 2>/dev/null; then
      echo 'Partial-output 1Password failure must fail' >&2
      exit 1
    fi
    if test -s "$TMPDIR/partial-identity"; then
      echo 'Partial-output 1Password failure must not release an identity' >&2
      exit 1
    fi
    if PATH="" ${operatorIdentity}/bin/cosmos-sops-identity > "$TMPDIR/denied" 2>/dev/null; then
      echo 'Missing op must fail' >&2
      exit 1
    fi
    test ! -s "$TMPDIR/denied"
    printf '%s\n' 'not-a-private-key' > "$TMPDIR/malformed-key"
    if FIXTURE_SSH_KEY="$TMPDIR/malformed-key" ${operatorIdentity}/bin/cosmos-sops-identity > "$TMPDIR/denied" 2>/dev/null; then
      echo 'Malformed key must fail' >&2
      exit 1
    fi
    test ! -s "$TMPDIR/denied"
    test ! -e "$XDG_CONFIG_HOME/sops/age/keys.txt"

    # Check the user's exact public-key conversion and real recipient policy.
    printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINuSOK2lyKYKS1Dczht47SHcbtulYQtfG3HCB1Vvw2D2' | ssh-to-age > "$TMPDIR/public-recipient"
    test "$(cat "$TMPDIR/public-recipient")" = age1gpztvjfd4x03hhq9cj0w4fy576lxr9mgqdzgm9zkldfqduptz3tq4s3vuy
    cp ${../.sops.yaml} "$TMPDIR/.sops.yaml"
    sops --config "$TMPDIR/.sops.yaml" encrypt --filename-override "$TMPDIR/secrets.yaml" \
      --input-type json --output-type json "$TMPDIR/plain.json" > "$TMPDIR/real-recipients.json"
    jq -e '[.sops.age[].recipient] == ["age1gpztvjfd4x03hhq9cj0w4fy576lxr9mgqdzgm9zkldfqduptz3tq4s3vuy", "age1uqzduhkwfyg5dgj04222ty620e8lup3wffgs0cv5e7gsxnlk8pcs9p9kw0", "age1cwuzsm66ewem2yry0pejqet0m6hqhruhv7lychvd5e6aaz2uh3ks66qnxc"]' "$TMPDIR/real-recipients.json" >/dev/null
    for filename in other.yaml secrets/odin/bootstrap.json secrets/thoth/bootstrap.json; do
      if sops --config "$TMPDIR/.sops.yaml" encrypt --filename-override "$TMPDIR/$filename" \
        --input-type json --output-type json "$TMPDIR/plain.json" > /dev/null 2>&1; then
        echo 'Only the shared secrets.yaml must match the creation policy' >&2
        exit 1
      fi
    done
    yq -o=json ${../secrets.yaml} > "$TMPDIR/committed.json"
    jq -e '.bootstrap_validation | startswith("ENC[")' "$TMPDIR/committed.json" >/dev/null
    diff <(jq -S '[.sops.age[].recipient]' "$TMPDIR/real-recipients.json") <(jq -S '[.sops.age[].recipient]' "$TMPDIR/committed.json")
    mkdir -p "$out"
    printf '%s\n' '${builtins.toJSON checks}' > "$out/checks.json"
    printf '%s\n' 'Fixture roundtrip, fail-closed helper, three independent recipients and shared-file policy passed.' > "$out/result.txt"
  ''
