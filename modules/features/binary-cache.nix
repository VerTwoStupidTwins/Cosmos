# modules/features/binary-cache.nix
let
  url = "https://cache.gatica.one";
  cache = "cosmos";
in
{
  # The homelab's binary cache, on lugh: Attic at cache.gatica.one, cache "cosmos". Hosts pull from it without a token
  # (only NetBird peers nginx lets in can reach it); pushing takes a token signed with the server's key (attic-server-env).
  # Builds nobody has fetched for 60 days are dropped, so it holds what the hosts actually run, not just lugh's last week.
  flake.modules.nixos.binary-cache =
    { config, ... }:
    let
      port = 8199;
    in
    {
      sops.secrets.attic-server-env.sopsFile = ../../secrets/${config.networking.hostName}.yaml;

      services.atticd = {
        enable = true;
        environmentFile = config.sops.secrets.attic-server-env.path;
        settings = {
          listen = "127.0.0.1:${toString port}";
          api-endpoint = "${url}/";
          allowed-hosts = [ "cache.gatica.one" ];
          garbage-collection = {
            interval = "12 hours";
            default-retention-period = "60 days";
          };
        };
      };

      # For the homelab map (modules/topology.nix).
      topology.self.services.attic = {
        name = "Attic";
        info = "cache.gatica.one";
        details.role.text = "Binary cache: what lugh and tenjin build, for every host to pull.";
      };

      web.sites.cache = {
        inherit port;
        # nabu pulls too (NetBird policy CosmosCache).
        peers = [ "nabu" ];
        extraConfig = ''
          # Pushes upload whole NARs.
          client_max_body_size 0;
          proxy_request_buffering off;
          proxy_read_timeout 600s;
        '';
      };

      monitor = {
        units = [ "atticd" ];
        ports.attic = port;
      };
    };

  # Pushes every new path in this host's store to the cache as it appears; Attic skips what cache.nixos.org already has.
  # On lugh that catches everything it builds for the others; on tenjin, what it builds itself.
  flake.modules.nixos.cache-push =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      sops.secrets.attic-push-token.sopsFile = ../../secrets/${config.networking.hostName}.yaml;

      systemd.services.attic-watch-store = {
        description = "Push new store paths to the binary cache";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        environment.XDG_CONFIG_HOME = "%t/attic-watch-store";
        script = ''
          ${lib.getExe pkgs.attic-client} login --set-default ${cache} ${url} "$(< "$CREDENTIALS_DIRECTORY/token")"
          exec ${lib.getExe pkgs.attic-client} watch-store ${cache}:${cache}
        '';
        serviceConfig = {
          DynamicUser = true;
          RuntimeDirectory = "attic-watch-store";
          LoadCredential = "token:${config.sops.secrets.attic-push-token.path}";
          Restart = "always";
          RestartSec = 30;
        };
      };

      monitor.units = [ "attic-watch-store" ];
    };

  # Pulls from the cache before building; cache.nixos.org stays first. A short timeout, so a down lugh only costs a few
  # seconds before Nix builds or goes elsewhere.
  flake.modules.nixos.cache-pull = {
    nix.settings = {
      extra-substituters = [ "${url}/${cache}" ];
      extra-trusted-public-keys = [ "@CACHE_PUBLIC_KEY@" ];
      connect-timeout = 5;
      fallback = true;
    };
  };
}
