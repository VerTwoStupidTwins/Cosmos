{ writeShellApplication, ssh-to-age }:
writeShellApplication {
  name = "cosmos-sops-identity";
  runtimeInputs = [ ssh-to-age ];
  text = ''
    # This stdout is private key material: only invoke as SOPS_AGE_KEY_CMD.
    # Inherited shell tracing must not log private identity assignments.
    set +x
    case "''${COSMOS_SOPS_OPERATOR_KEY_REF:-}" in
      op://*\?ssh-format=openssh) ;;
      *)
        printf '%s\n' 'Set COSMOS_SOPS_OPERATOR_KEY_REF to the 1Password private-key reference with ?ssh-format=openssh.' >&2
        exit 1
        ;;
    esac
    if ! command -v op >/dev/null 2>&1; then
      printf '%s\n' '1Password CLI is required on the editing client; it is not installed on Odin by this bootstrap.' >&2
      exit 1
    fi
    # Release an identity only after the complete pipeline has succeeded.
    if ! identity="$(op read "$COSMOS_SOPS_OPERATOR_KEY_REF" | ssh-to-age -private-key)"; then
      printf '%s\n' 'Operator identity retrieval failed; no identity released.' >&2
      exit 1
    fi
    printf '%s\n' "$identity"
  '';
}
