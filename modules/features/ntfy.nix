# modules/features/ntfy.nix
{
  # Push notifications for the homelab: ntfy at ntfy.gatica.one, over NetBird only. The phone runs the ntfy app
  # with NetBird, and Alertmanager publishes to the homelab topic. Nobody can read or publish without an account:
  # twins (admin, for the phone) and alertmanager (publish to homelab only, by token). The users, their password
  # hashes and the token come from the ntfy-env secret; twins' password is in ntfy-twins-password.
  flake.modules.nixos.ntfy =
    { config, ... }:
    let
      port = 2586;
    in
    {
      sops.secrets.ntfy-env.sopsFile = ../../secrets/${config.networking.hostName}.yaml;

      services.ntfy-sh = {
        enable = true;
        environmentFile = config.sops.secrets.ntfy-env.path;
        settings = {
          base-url = "https://ntfy.gatica.one";
          listen-http = "127.0.0.1:${toString port}";
          behind-proxy = true;
          auth-default-access = "deny-all";
          # Lets the phone's app get messages it missed while it was off the mesh.
          cache-duration = "72h";
        };
      };

      # For the homelab map (modules/topology.nix).
      topology.self.services.ntfy = {
        name = "ntfy";
        info = "ntfy.gatica.one";
        details.role.text = "Push notifications to the owner's phone (Alertmanager alerts).";
      };

      web.sites.ntfy = {
        healthPath = "/v1/health";
        inherit port;
        websockets = true;
        homepage = {
          name = "ntfy";
          group = "Monitoring";
          icon = "ntfy.png";
          description = "Alerts to the phone";
        };
      };

      monitor = {
        units = [ "ntfy-sh" ];
        ports.ntfy = port;
      };
    };
}
