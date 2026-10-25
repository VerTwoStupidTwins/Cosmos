# Optional local Honcho integration; never grant server or container authority.
_: {
  flake.modules.nixos."hermes-honcho" = _: {
    services.hermes-agent = {
      settings.memory.provider = "honcho";
      privateHomeFiles."honcho.json" = "/var/lib/cosmos-honcho/client.json";
    };
    systemd.services = {
      hermes-state-setup = {
        after = [ "honcho-credentials.service" ];
        requires = [ "honcho-credentials.service" ];
      };
      # Order initial provider setup after readiness, but do not make chat's
      # availability require the memory backend to remain up.
      hermes-agent = {
        wants = [ "podman-honcho-api.service" ];
        after = [ "podman-honcho-api.service" ];
      };
      hermes-backend = {
        wants = [ "podman-honcho-api.service" ];
        after = [ "podman-honcho-api.service" ];
      };
    };
  };
}
