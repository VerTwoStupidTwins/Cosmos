# modules/features/memory-store.nix
{
  # Qdrant, the search index of the agent's long-term memory (agent.nix runs the memory server that owns it). It holds
  # only what the memory server's SQLite file holds, so it can be wiped and rebuilt from that at any time. It listens
  # on localhost; its dashboard is at memory.gatica.one (mesh only), opened with the read-only key.
  flake.modules.nixos.memory-store =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      port = 6333;
      hostSecrets = ../../secrets/${config.networking.hostName}.yaml;
    in
    {
      # The read/write key is the memory server's; the read-only key opens the dashboard and lets Prometheus scrape.
      sops.secrets.qdrant-api-key.sopsFile = hostSecrets;
      sops.secrets.qdrant-read-key = {
        sopsFile = hostSecrets;
        owner = lib.mkIf config.services.prometheus.enable "prometheus";
      };
      sops.templates."qdrant.env".content = ''
        QDRANT__SERVICE__API_KEY=${config.sops.placeholder.qdrant-api-key}
        QDRANT__SERVICE__READ_ONLY_API_KEY=${config.sops.placeholder.qdrant-read-key}
      '';

      services.qdrant = {
        enable = true;
        # nixpkgs' 1.18.2 fails to build: its zstd-sys looks for the system libzstd through pkg-config, which the
        # package doesn't provide. Its own test suite is skipped; the memory server's tests run against it instead.
        package = pkgs.qdrant.overrideAttrs (old: {
          buildInputs = old.buildInputs ++ [ pkgs.zstd ];
          doCheck = false;
        });
        settings = {
          service = {
            host = "127.0.0.1";
            http_port = port;
            grpc_port = null; # REST only
            enable_cors = false;
          };
          telemetry_disabled = true;
          # Its metrics read /proc/sys/vm/max_map_count, which the service's sandbox hides, and warn every 30 s.
          log_level = "INFO,qdrant::common::metrics=error";
        };
      };
      # The keys come from the environment, never the config file in the Nix store.
      systemd.services.qdrant.serviceConfig.EnvironmentFile = config.sops.templates."qdrant.env".path;

      web.sites.memory = {
        inherit port;
        healthPath = "/healthz";
      };

      # promtool can't check a credentials file that only exists at runtime (sops), so only the syntax is checked.
      services.prometheus.checkConfig = lib.mkIf config.services.prometheus.enable "syntax-only";
      services.prometheus.scrapeConfigs = lib.mkIf config.services.prometheus.enable [
        {
          job_name = "qdrant";
          static_configs = [
            {
              targets = [ "127.0.0.1:${toString port}" ];
              labels.host = config.networking.hostName;
            }
          ];
          authorization.credentials_file = config.sops.secrets.qdrant-read-key.path;
        }
      ];

      monitor.units = [ "qdrant" ];
    };
}
