# modules/features/dns.nix
# DNS for the owner's devices: Blocky on lugh and nabu, handed out by NetBird as one nameserver group (port 5300), so a
# device fails over to the other when one is down. It blocks ads, trackers and malware, answers *.gatica.one itself
# (every site lives on lugh), and asks Quad9 and Cloudflare over HTTPS for the rest. No query log: only counts, for
# Prometheus.
#
# Port 5300, not 53: NetBird's own forwarder already sits on each peer's NetBird address and handles :53 there.
{ config, ... }:
let
  dnsHosts = [
    "lugh"
    "nabu"
  ];
  ports = {
    dns = 5300;
    http = 4000;
  };
  lugh = config.cosmos.netbird.peers.lugh.ip;
in
{
  flake.modules.nixos.dns = {
    services.blocky = {
      enable = true;
      settings = {
        ports = {
          dns = ports.dns;
          http = ports.http;
        };

        upstreams = {
          groups.default = [
            "https://dns.quad9.net/dns-query"
            "https://cloudflare-dns.com/dns-query"
          ];
          strategy = "parallel_best";
          timeout = "2s";
        };
        # Neither host has an IPv6 route out; without this every upstream tries IPv6 first and waits for it to fail.
        connectIPVersion = "v4";
        # Resolves the upstreams' own names, before there is anyone else to ask.
        bootstrapDns = [
          {
            upstream = "https://dns.quad9.net/dns-query";
            ips = [
              "9.9.9.9"
              "149.112.112.112"
            ];
          }
          {
            upstream = "https://cloudflare-dns.com/dns-query";
            ips = [
              "1.1.1.1"
              "1.0.0.1"
            ];
          }
        ];

        # gatica.one and every name under it. The public records stay for devices that don't use this server (the
        # brother's, for the shared sites).
        customDNS.mapping."gatica.one" = lugh;

        blocking = {
          # Wildcard lists (*.example.com): Blocky matches a bare domain only exactly, so a plain list would let every
          # subdomain of a listed tracker through.
          denylists.ads = [
            "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.txt"
            "https://big.oisd.nl/domainswild"
          ];
          clientGroupsBlock.default = [ "ads" ];
          blockType = "zeroIp";
          loading = {
            refreshPeriod = "24h";
            # Answer right away on start and block once the lists are in, instead of holding queries.
            strategy = "fast";
            downloads = {
              timeout = "60s";
              attempts = 5;
            };
          };
        };

        caching = {
          prefetching = true;
          minTime = "5m";
        };

        prometheus.enable = true;
        queryLog.type = "none";
      };
    };

    networking.firewall.interfaces."nb-wt0" = {
      allowedUDPPorts = [ ports.dns ];
      allowedTCPPorts = [
        ports.dns
        ports.http
      ];
    };

    # For the homelab map (modules/topology.nix).
    topology.self.services.blocky = {
      name = "Blocky";
      info = "DNS on :${toString ports.dns}";
      details.role.text = "DNS for the owner's devices through NetBird: blocking, and *.gatica.one answered locally.";
    };

    monitor = {
      units = [ "blocky" ];
      ports.blocky = ports.dns;
    };
  };

  # lugh watches both: Blocky's metrics, and a probe that asks each for grafana.gatica.one (ProbeFailed if one stops).
  flake.modules.nixos.observability =
    { pkgs, ... }:
    {
      services.prometheus.scrapeConfigs = [
        {
          job_name = "blocky";
          static_configs = map (h: {
            targets = [ "${h}.netbird.cloud:${toString ports.http}" ];
            labels.host = h;
          }) dnsHosts;
        }
      ];
      observability.dnsProbeTargets = map (h: "${h}.netbird.cloud:${toString ports.dns}") dnsHosts;
      observability.dashboards = [
        {
          name = "blocky.json";
          path = pkgs.fetchurl {
            url = "https://grafana.com/api/dashboards/13768/revisions/8/download";
            hash = "sha256-gwPOcnVC7BXTlhOCRvENAXZfGdQGVCPEUrLCl4ASkVE=";
          };
        }
      ];
    };
}
