{
  pkgs,
  odin,
  thoth,
  argus,
}:
let
  inherit (pkgs) lib;
  homarr = odin.virtualisation.oci-containers.containers.homarr;
  checks = {
    rootlessHomarr =
      homarr.podman.user == "homarr"
      && !homarr.privileged
      && homarr.pull == "never"
      && homarr.imageFile != null
      && homarr.ports == [ "127.0.0.1:17575:7575" ]
      && homarr.volumes == [ "/var/lib/homarr/appdata:/appdata" ];
    noContainerManagement =
      homarr.environment.ENABLE_DOCKER == "false" && homarr.environment.ENABLE_KUBERNETES == "false";
    privateMetrics =
      odin.services.prometheus.listenAddress == "127.0.0.1"
      && odin.services.prometheus.exporters.node.listenAddress == "127.0.0.1"
      && odin.services.prometheus.exporters.blackbox.listenAddress == "127.0.0.1"
      && !(builtins.elem 9090 odin.networking.firewall.allowedTCPPorts)
      && !odin.services.prometheus.exporters.node.openFirewall
      && !odin.services.prometheus.exporters.blackbox.openFirewall;
    boundedRetention =
      odin.services.prometheus.retentionTime == "30d"
      && builtins.elem "--storage.tsdb.retention.size=10GB" odin.services.prometheus.extraFlags;
    authenticatedGrafana =
      !odin.services.grafana.settings."auth.anonymous".enabled
      && !odin.services.grafana.settings.users.allow_sign_up
      && lib.hasPrefix "$__file{" odin.services.grafana.settings.security.admin_password
      && lib.hasPrefix "$__file{" odin.services.grafana.settings.security.secret_key
      && odin.services.grafana.settings.server.http_addr == "127.0.0.1";
    privateCredentials =
      odin.systemd.services.dashboard-credentials.serviceConfig.StateDirectoryMode == "0700"
      &&
        odin.systemd.services.podman-homarr.serviceConfig.EnvironmentFile
        == [ "/var/lib/cosmos-dashboard-credentials/homarr.env" ]
      && !(homarr.environment ? SECRET_ENCRYPTION_KEY)
      && builtins.elem "dashboard-credentials.service" odin.systemd.services.grafana.requires;
    netbirdIngress =
      builtins.all
        (
          port:
          builtins.elem port odin.networking.firewall.interfaces.wt0.allowedTCPPorts
          && !(builtins.elem port odin.networking.firewall.allowedTCPPorts)
        )
        [
          3000
          7575
        ];
    otherHostsUnchanged =
      builtins.all
        (
          host:
          !host.services.prometheus.enable
          && !host.services.grafana.enable
          && !(host.virtualisation.oci-containers.containers ? homarr)
        )
        [
          thoth
          argus
        ];
  };
  failures = builtins.attrNames (lib.filterAttrs (_: passed: !passed) checks);
  dashboard = builtins.fromJSON (builtins.readFile ../packages/grafana-dashboards/odin.json);
  credentialSetup = pkgs.writeShellScript "dashboard-credentials-fixture" (
    lib.replaceStrings [ "/var/lib/cosmos-dashboard-credentials" ] [ "$TMPDIR/secrets" ]
      odin.systemd.services.dashboard-credentials.script
  );
  # Use promtool's parser to catch invalid expressions without starting a server.
  rules = (pkgs.formats.yaml { }).generate "dashboard-query-check.yml" {
    groups = [
      {
        name = "dashboard";
        rules = map (panel: {
          record = "cosmos:panel_${toString panel.id}";
          inherit (builtins.head panel.targets) expr;
        }) dashboard.panels;
      }
    ];
  };
in
assert lib.assertMsg (
  failures == [ ]
) "Odin dashboard checks failed: ${lib.concatStringsSep ", " failures}";
pkgs.runCommand "odin-dashboard-check" { } ''
  ${pkgs.prometheus.cli}/bin/promtool check rules ${rules}
  umask 0077
  mkdir -m 0700 "$TMPDIR/secrets"
  ${credentialSetup}
  sha256sum "$TMPDIR"/secrets/* > before
  ${credentialSetup}
  sha256sum --check before
  for secret in "$TMPDIR"/secrets/*; do
    test "$(stat -c %a "$secret")" = 600
  done
  # An empty existing key must fail, never silently rotate encrypted state.
  : > "$TMPDIR/secrets/homarr.env"
  if ${credentialSetup}; then
    echo 'Empty existing Homarr key was accepted' >&2
    exit 1
  fi
  mkdir "$out"
  printf '%s\n' '${builtins.toJSON checks}' > "$out/checks.json"
''
