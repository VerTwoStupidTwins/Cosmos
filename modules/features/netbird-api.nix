# modules/features/netbird-api.nix
# Read-only access to the NetBird account's settings (policies, groups, peers), so the policy list in
# modules/base/netbird.nix can be checked against what is really set. The token belongs to a NetBird service user with
# the read-only Auditor role (CosmosAuditor; sops: netbird-api-token in secrets/common.yaml), so nothing here can change
# the account (a write was refused with 403 when it was set up). The token expires 2027-11-22: then `netbird-api` fails
# with 401, and a new token from the dashboard goes into the same sops key.
#
#   netbird-api policies   who may reach what, one line per rule (like the dashboard's policy list)
#   netbird-api groups     each group and its peers
#   netbird-api peers      each peer: NetBird IP, DNS name, connected, groups
#   netbird-api raw <path> any GET of the API, as JSON (e.g. raw policies)
{
  flake.modules.nixos.netbird-api =
    { config, pkgs, ... }:
    {
      sops.secrets.netbird-api-token = {
        sopsFile = ../../secrets/common.yaml;
        owner = "twins";
        mode = "0400";
      };

      environment.systemPackages = [
        (pkgs.writeShellApplication {
          name = "netbird-api";
          runtimeInputs = with pkgs; [
            coreutils
            curl
            jq
          ];
          text = ''
            token_file=${config.sops.secrets.netbird-api-token.path}
            get() {
              # The token goes in a header file, so it never shows in the process list.
              header=$(mktemp)
              trap 'rm -f "$header"' RETURN
              printf 'authorization: Token %s\n' "$(cat "$token_file")" > "$header"
              curl -fsS --max-time 20 -H @"$header" -H 'accept: application/json' "https://api.netbird.io/api/$1"
            }
            case "''${1:-policies}" in
              policies)
                get policies | jq -r '.[] | . as $p | .rules[] |
                  "\(if $p.enabled then "on " else "off" end)  \($p.name): \([.sources[]?.name] | join(","))"
                  + " \(if .bidirectional then "<->" else "->" end) \([.destinations[]?.name] | join(","))"
                  + "  \(.protocol | ascii_upcase) \(if (.ports // []) == [] and (.port_ranges // []) == [] then "all" else ((.ports // []) + [(.port_ranges // [])[] | "\(.start)-\(.end)"] | join(",")) end)"
                  + "\(if ($p.description // "") != "" then "  # \($p.description)" else "" end)"'
                ;;
              groups)
                get groups | jq -r '.[] | "\(.name) (\(.peers_count) peers): \([.peers[]?.name] | join(", "))"'
                ;;
              peers)
                get peers | jq -r '.[] | "\(.name)  \(.ip)  \(.dns_label)  \(if .connected then "connected" else "offline" end)  [\([.groups[]?.name] | join(", "))]"'
                ;;
              raw)
                get "''${2:?raw needs an API path, e.g. raw policies}" | jq .
                ;;
              *)
                echo "netbird-api policies | groups | peers | raw <path>" >&2
                exit 2
                ;;
            esac
          '';
        })
      ];
    };
}
