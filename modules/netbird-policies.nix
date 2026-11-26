# modules/netbird-policies.nix
# Who may reach what over NetBird: the groups and access policies of the (shared) NetBird account, as data. NetBird
# drops anything no policy allows, before the hosts' own firewalls see it, and its policies only ever allow, so no broad
# policy (NetBird's default "All", a group-wide all-to-all) may cover the homelab's hosts.
#
# The dashboard is where policies are made (the repo has read-only access, CosmosAuditor); this file says what should be
# there and why. From it:
#   - the homelab map (modules/topology.nix) gains each host's groups and an "Access over NetBird" section;
#   - the agent's netbird_access tool, view "drift", compares it with the live account (missing, extra, changed), and
#     the morning check mentions any drift.
# So: change a policy in the dashboard, then here (or the morning check will say they disagree).
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.cosmos.netbird = {
    peers = mkOption {
      description = "The owner's peers and their NetBird IPs (stable per peer), for things that allow by address, like the private web sites.";
      type = types.attrsOf (types.submodule { options.ip = mkOption { type = types.str; }; });
    };

    # The addresses a private web site (web.sites.<name>.shared = false) answers: the owner's devices and lugh itself.
    privateSiteClients = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      default =
        let
          cfg = config.cosmos.netbird;
          members = lib.unique (cfg.groups.CosmosAdmin.members ++ cfg.groups.CosmosInfra.members);
        in
        map (m: cfg.peers.${m}.ip) members;
    };

    groups = mkOption {
      description = "NetBird groups, by their name in the dashboard.";
      type = types.attrsOf (
        types.submodule {
          options = {
            members = mkOption {
              type = types.nullOr (types.listOf types.str);
              default = null;
              description = "Its peers, by NetBird peer name; null: not checked (someone else's group, or built in).";
            };
            known = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "For a group whose members aren't checked: the ones of ours known to be in it (for the map only).";
            };
            owner = mkOption {
              type = types.str;
              default = "owner";
              description = "Whose it is: the owner's, the brother's, or NetBird's (built in).";
            };
            description = mkOption {
              type = types.str;
              default = "";
            };
          };
        }
      );
    };

    policies = mkOption {
      description = "NetBird access policies, by their name in the dashboard. Each is one rule.";
      type = types.attrsOf (
        types.submodule {
          options = {
            from = mkOption { type = types.listOf types.str; };
            to = mkOption { type = types.listOf types.str; };
            protocol = mkOption {
              type = types.enum [
                "all"
                "tcp"
                "udp"
                "icmp"
              ];
            };
            ports = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Destination ports; empty: all.";
            };
            bidirectional = mkOption {
              type = types.bool;
              default = false;
            };
            owner = mkOption {
              type = types.str;
              default = "owner";
            };
            why = mkOption { type = types.str; };
            broad = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Set on a deliberately broad policy: why, and until when.";
            };
          };
        }
      );
    };
  };

  config.cosmos.netbird = {
    peers = {
      tenjin.ip = "100.94.61.153";
      akita.ip = "100.94.136.207";
      lugh.ip = "100.94.36.6";
      nabu.ip = "100.94.123.249";
      hestia.ip = "100.94.252.21";
    };

    groups = {
      All = {
        owner = "NetBird";
        description = "built in: every peer; no policy may use it";
      };
      CosmosAdmin = {
        members = [
          "tenjin"
          "akita"
        ];
        description = "the owner's devices: tenjin and the phone (akita)";
      };
      CosmosServers = {
        members = [
          "lugh"
          "nabu"
        ];
        description = "the homelab servers";
      };
      CosmosWatched = {
        members = [
          "lugh"
          "nabu"
          "tenjin"
        ];
        description = "hosts lugh monitors (metrics, logs)";
      };
      CosmosInfra = {
        members = [ "lugh" ];
        description = "the infrastructure server";
      };
      SharedNas = {
        members = [ "hestia" ];
        description = "the NAS shared with the brother (hestia), on the LAN but always reached over NetBird";
      };
      players = {
        description = "the owner's tabletop players' devices, joined with the players setup key (it puts them here); not checked, since they come and go";
      };
      Olympus = {
        owner = "brother";
        known = [ "hestia" ];
        description = "the brother's devices (hestia, the NAS, among them); his to change, so not checked";
      };
    };

    policies = {
      CosmosAdminAccess = {
        from = [ "CosmosAdmin" ];
        to = [ "CosmosServers" ];
        protocol = "all";
        why = "tenjin and the phone manage the servers: SSH, remote builds, the homelab plate, Grafana, ntfy";
      };
      CosmosMetrics = {
        from = [ "CosmosInfra" ];
        to = [ "CosmosWatched" ];
        protocol = "tcp";
        ports = [
          "9100"
          "9633"
          "9835"
          "4000"
        ];
        why = "Prometheus on lugh scrapes the exporters (observed.nix) and Blocky (4000, dns.nix)";
      };
      CosmosPing = {
        from = [ "CosmosInfra" ];
        to = [ "CosmosServers" ];
        protocol = "icmp";
        why = "lugh's blackbox ping probes (observability.nix)";
      };
      CosmosLogs = {
        from = [ "CosmosWatched" ];
        to = [ "CosmosInfra" ];
        protocol = "tcp";
        ports = [ "3100" ];
        why = "Alloy pushes journals to Loki on lugh";
      };
      CosmosModels = {
        from = [ "CosmosInfra" ];
        to = [ "CosmosServers" ];
        protocol = "tcp";
        ports = [ "8080" ];
        why = "the agent on lugh uses nabu's models (llama-swap)";
      };
      CosmosDNS = {
        from = [
          "CosmosAdmin"
          "CosmosInfra"
        ];
        to = [ "CosmosServers" ];
        protocol = "udp";
        ports = [ "5300" ];
        why = "the owner's devices use Blocky on lugh and nabu (nameserver group Cosmos DNS, dns.nix); lugh probes both";
      };
      CosmosCache = {
        from = [ "CosmosServers" ];
        to = [ "CosmosInfra" ];
        protocol = "tcp";
        ports = [ "443" ];
        why = "nabu pulls from the binary cache, cache.gatica.one on lugh (binary-cache.nix; nginx lets it in by web.sites.cache.peers)";
      };
      CosmosNasProxy = {
        from = [ "CosmosInfra" ];
        to = [ "SharedNas" ];
        protocol = "tcp";
        why = "lugh's nginx fronts the NAS's web services (web.sites.<name>.upstream)";
        broad = "all TCP until the mapped ports are settled (2026-11-22)";
      };
      CosmosNasDirect = {
        from = [ "CosmosAdmin" ];
        to = [ "SharedNas" ];
        protocol = "tcp";
        why = "the owner's devices reach the NAS directly: NFS (2049), its admin pages";
        broad = "all TCP until the used ports are settled (2026-11-22)";
      };
      CosmosSitesShared = {
        from = [ "Olympus" ];
        to = [ "CosmosInfra" ];
        protocol = "tcp";
        ports = [ "443" ];
        why = "the brother's devices reach the *.gatica.one sites on lugh, but nginx only lets them into the shared ones (the NAS's services; web.sites.<name>.shared): the others answer 403 to anyone but the owner's devices";
      };
      CosmosPlayers = {
        from = [ "players" ];
        to = [ "CosmosInfra" ];
        protocol = "tcp";
        ports = [ "443" ];
        why = "players reach Foundry VTT (foundry.gatica.one, a shared site, modules/features/foundry.nix); nginx answers them 403 everywhere else";
      };
      "Homelab Access" = {
        from = [ "Olympus" ];
        to = [ "Olympus" ];
        protocol = "all";
        bidirectional = true;
        owner = "brother";
        why = "the brother's devices reach each other, the NAS (hestia) included: his NFS mounts";
      };
    };
  };
}
