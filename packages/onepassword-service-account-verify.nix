{
  writeShellApplication,
  opPackage,
  jq,
}:
writeShellApplication {
  name = "cosmos-onepassword-verify";
  runtimeInputs = [
    opPackage
    jq
  ];
  text = ''
    # Credentials must never be expanded into shell traces or provider logs.
    set +x
    if [[ "$#" -ne 2 || ! -f "$1" || ! -r "$1" ]]; then
      printf '%s\n' 'A readable token credential and runtime vault are required.' >&2
      exit 1
    fi
    OP_SERVICE_ACCOUNT_TOKEN="$(< "$1")"
    if [[ -z "$OP_SERVICE_ACCOUNT_TOKEN" ]]; then
      printf '%s\n' 'The service-account credential is empty.' >&2
      exit 1
    fi
    case "$OP_SERVICE_ACCOUNT_TOKEN" in
      ops_?*) ;;
      *) printf '%s\n' 'The credential is not a 1Password service-account token.' >&2; exit 1 ;;
    esac
    export OP_SERVICE_ACCOUNT_TOKEN OP_CACHE=false OP_DEBUG=false OP_BIOMETRIC_UNLOCK_ENABLED=false
    unset OP_CONNECT_HOST OP_CONNECT_TOKEN OP_ACCOUNT OP_SESSION
    for variable in "''${!OP_SESSION_@}"; do unset "$variable"; done
    if ! identity="$(op --cache=false --format=json user get --me 2>/dev/null)"; then
      printf '%s\n' '1Password service-account authentication failed; provider output suppressed.' >&2
      exit 1
    fi
    if ! jq -e '.type == "SERVICE_ACCOUNT"' <<< "$identity" >/dev/null 2>&1; then
      printf '%s\n' '1Password did not confirm a service-account identity.' >&2
      exit 1
    fi
    if ! op --cache=false --format=json item list --vault "$2" >/dev/null 2>&1; then
      printf '%s\n' '1Password runtime-vault access failed; provider output suppressed.' >&2
      exit 1
    fi
    printf '%s\n' '1Password service-account authentication and runtime-vault access verified.'
  '';
}
