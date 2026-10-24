# Disposable provider fixtures only: never authenticate to 1Password in CI.
{
  pkgs,
  odin,
  thoth,
  argus,
}:
let
  inherit (pkgs) lib;
  service = odin.systemd.services.onepassword-service-account-verify;
  token = odin.sops.secrets.onepassword-service-account-token;
  allowed = name: odin.nixpkgs.config.allowUnfreePredicate { inherit name; };
  checks = {
    isolatedVerifier = service.serviceConfig.DynamicUser && service.serviceConfig.NoNewPrivileges;
    runtimeCredential = service.serviceConfig.LoadCredential == [ "token:${token.path}" ];
    rootOnlyToken = token.owner == "root" && token.group == "root" && token.mode == "0400";
    sharedEncryptedFile =
      token.sopsFile == odin.sops.defaultSopsFile && token.key == "onepassword_service_account_token";
    noTokenInUnitEnvironment = !(service.environment ? OP_SERVICE_ACCOUNT_TOKEN);
    noGuiOnOdin = !odin.programs._1password-gui.enable;
    noOtherHostService =
      !(thoth.systemd.services ? onepassword-service-account-verify)
      && !(argus.systemd.services ? onepassword-service-account-verify);
    narrowLicenseExceptions =
      allowed "1password-cli" && allowed "intel-oneapi-toolkit" && !allowed "unrelated-unfree-package";
    preservedWorkstationLicenses =
      builtins.all (name: thoth.nixpkgs.config.allowUnfreePredicate { inherit name; })
        [
          "1password"
          "1password-cli"
          "1password-gui"
        ];
    preservedNvrLicenses =
      argus.nixpkgs.config.allowUnfreePredicate { name = "nvidia-x11"; }
      && !(argus.nixpkgs.config.allowUnfreePredicate { name = "1password-cli"; });
    privateKeyPathsHidden =
      service.serviceConfig.InaccessiblePaths == [
        "/etc/ssh"
        "/run/secrets"
      ];
  };
  failures = builtins.attrNames (lib.filterAttrs (_: passed: !passed) checks);
  fakeOp = pkgs.writeShellScriptBin "op" ''
    set -euo pipefail
    if test -n "''${CALL_MARKER:-}"; then : > "$CALL_MARKER"; fi
    # This string is a public fixture, not a 1Password credential.
    test "$OP_SERVICE_ACCOUNT_TOKEN" = 'ops_public_fixture_not_a_real_token'
    test "$OP_CACHE" = false
    test "$OP_DEBUG" = false
    test "$OP_BIOMETRIC_UNLOCK_ENABLED" = false
    test -z "''${OP_CONNECT_HOST+x}''${OP_CONNECT_TOKEN+x}''${OP_ACCOUNT+x}''${OP_SESSION+x}''${OP_SESSION_fixture+x}"
    if test "''${MODE:-ok}" = fail; then
      printf '%s\n' '{"type":"SERVICE_ACCOUNT"}'
      printf '%s\n' "$OP_SERVICE_ACCOUNT_TOKEN" >&2
      exit 17
    fi
    case "$*" in
      '--cache=false --format=json user get --me')
        case "''${MODE:-ok}" in
          malformed) printf '%s\n' "$OP_SERVICE_ACCOUNT_TOKEN" ;;
          human) printf '%s\n' '{"type":"MEMBER"}' ;;
          *) printf '%s\n' '{"type":"SERVICE_ACCOUNT"}' ;;
        esac ;;
      '--cache=false --format=json item list --vault Fixture Runtime')
        if test "''${MODE:-ok}" = vault-fail; then
          printf '%s\n' "$OP_SERVICE_ACCOUNT_TOKEN"
          printf '%s\n' "$OP_SERVICE_ACCOUNT_TOKEN" >&2
          exit 19
        fi
        printf '%s\n' '[]' ;;
      *) exit 23 ;;
    esac
  '';
  helper = pkgs.callPackage ../packages/onepassword-service-account-verify.nix {
    opPackage = fakeOp;
  };
in
assert lib.assertMsg (failures == [ ]) (
  "1Password service-account checks failed: " + lib.concatStringsSep ", " failures
);
pkgs.runCommand "onepassword-service-account-check"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.yq-go
    ];
  }
  ''
    set +x
    umask 077
    printf '%s' 'ops_public_fixture_not_a_real_token' > "$TMPDIR/token"
    export OP_CONNECT_HOST=unwanted OP_CONNECT_TOKEN=unwanted OP_ACCOUNT=unwanted OP_SESSION=unwanted OP_SESSION_fixture=unwanted
    ${helper}/bin/cosmos-onepassword-verify "$TMPDIR/token" 'Fixture Runtime' > "$TMPDIR/result"
    grep -Fx '1Password service-account authentication and runtime-vault access verified.' "$TMPDIR/result" >/dev/null
    for mode in fail malformed human vault-fail; do
      if MODE="$mode" ${helper}/bin/cosmos-onepassword-verify "$TMPDIR/token" 'Fixture Runtime' > "$TMPDIR/denied" 2>&1; then
        echo "Provider refusal case must fail: $mode" >&2
        exit 1
      fi
      if grep -q 'ops_public_fixture_not_a_real_token' "$TMPDIR/denied"; then
        echo 'A provider failure exposed its credential' >&2
        exit 1
      fi
    done
    printf '%s\n' 'set -x' > "$TMPDIR/enable-tracing"
    BASH_ENV="$TMPDIR/enable-tracing" ${helper}/bin/cosmos-onepassword-verify "$TMPDIR/token" 'Fixture Runtime' > "$TMPDIR/traced" 2>&1
    if grep -q 'ops_public_fixture_not_a_real_token' "$TMPDIR/traced"; then
      echo 'Inherited tracing exposed the credential' >&2
      exit 1
    fi
    for input in missing empty malformed-token; do
      test "$input" = missing || : > "$TMPDIR/$input"
      test "$input" != malformed-token || printf '%s' 'not-a-service-account-token' > "$TMPDIR/$input"
      if CALL_MARKER="$TMPDIR/called-$input" ${helper}/bin/cosmos-onepassword-verify "$TMPDIR/$input" 'Fixture Runtime' > "$TMPDIR/denied" 2>&1; then
        echo "Invalid credential must be rejected: $input" >&2
        exit 1
      fi
      if test -e "$TMPDIR/called-$input"; then
        echo "Invalid credential reached the provider: $input" >&2
        exit 1
      fi
    done
    yq -o=json ${../secrets.yaml} | jq -e '.onepassword_service_account_token | startswith("ENC[")' >/dev/null
    mkdir -p "$out"
    printf '%s\n' '${builtins.toJSON checks}' > "$out/checks.json"
    printf '%s\n' 'Isolation, licensing, provider failure, wrong identity, tracing and credential validation passed.' > "$out/result.txt"
  ''
