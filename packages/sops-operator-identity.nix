{
  writeShellApplication,
  ssh-to-age,
  jq,
}:
writeShellApplication {
  name = "cosmos-sops-identity";
  runtimeInputs = [
    ssh-to-age
    jq
  ];
  text = ''
    # This stdout is private key material: only invoke as SOPS_AGE_KEY_CMD.
    # Inherited shell tracing must not log metadata or private assignments.
    set +x
    if ! command -v op >/dev/null 2>&1; then
      printf '%s\n' '1Password CLI is required on the editing client.' >&2
      exit 1
    fi
    operator_ref="''${COSMOS_SOPS_OPERATOR_KEY_REF:-}"
    if [ -z "$operator_ref" ]; then
      if ! operator_ref="$(op item list --format=json 2>/dev/null | jq -er '
        [.[] | select(.title == "Cosmos SOPS Operator" and .category == "SSH_KEY")]
        | if length == 1 then
            .[0] | "op://\(.vault.id)/\(.id)/private_key?ssh-format=openssh"
          else error("Expected exactly one operator SSH key") end
      ' 2>/dev/null)"; then
        printf '%s\n' 'Operator item discovery failed; authorize the 1Password CLI and ensure exactly one Cosmos SOPS Operator SSH key is accessible.' >&2
        exit 1
      fi
    fi
    case "$operator_ref" in
      op://*\?ssh-format=openssh) ;;
      *)
        printf '%s\n' 'The operator reference must name a 1Password private key with ?ssh-format=openssh.' >&2
        exit 1
        ;;
    esac
    # Release an identity only after the complete pipeline has succeeded.
    if ! identity="$(op read "$operator_ref" 2>/dev/null | ssh-to-age -private-key 2>/dev/null)"; then
      printf '%s\n' 'Operator identity retrieval failed; no identity released.' >&2
      exit 1
    fi
    printf '%s\n' "$identity"
  '';
}
