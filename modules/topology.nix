# modules/topology.nix
# The homelab's map, from the NixOS configs themselves (nix-topology): every host's services are read from its config;
# the physical side (the LAN, the router, the NetBird mesh, which interface goes where) is written here, because the
# hosts use NetworkManager, which nix-topology can't read. Build the diagrams with `nix build .#topology.x86_64-linux.config.output`.
#
# The same data is also written out as text (homelab-map.md) for the agent's homelab_map tool, so the models can answer
# "how is X connected?" from the deployed config itself.
{
  config,
  inputs,
  lib,
  ...
}:
let
  # The map as markdown: networks, then each node with its hardware, interfaces (network, addresses, cabling) and
  # services (what they are, where they answer, details).
  render =
    topology:
    let
      inherit (lib)
        concatStringsSep
        concatMapStringsSep
        mapAttrsToList
        optionalString
        filterAttrs
        ;
      networks = topology.networks;
      networkName =
        id: if id != null && networks ? ${id} then "${networks.${id}.name} (${id})" else "no network";
      interface =
        name: i:
        let
          links = map (c: "${c.node}:${c.interface}") i.physicalConnections;
        in
        "- ${name}${optionalString i.virtual " (virtual)"}: ${networkName i.network}"
        + optionalString (i.addresses != [ ]) ", ${concatStringsSep ", " i.addresses}"
        + optionalString (links != [ ]) "; cabled/linked to ${concatStringsSep ", " links}";
      service =
        _: sv:
        let
          details = mapAttrsToList (k: d: "${k}: ${d.text}") sv.details;
        in
        "- ${sv.name}${optionalString (sv.info != "") " — ${sv.info}"}"
        + optionalString (details != [ ]) "\n${concatMapStringsSep "\n" (d: "  - ${d}") details}";
      node =
        name: n:
        let
          used = filterAttrs (
            _: i: i.network != null || i.addresses != [ ] || i.physicalConnections != [ ]
          ) n.interfaces;
          unused = lib.attrNames (removeAttrs n.interfaces (lib.attrNames used));
          services = filterAttrs (_: sv: !sv.hidden) n.services;
        in
        concatStringsSep "\n" (
          [ "### ${name} (${n.deviceType})" ]
          ++ lib.optional (n.hardware.info != "") "Hardware: ${n.hardware.info}"
          ++ [ "Interfaces:" ]
          ++ mapAttrsToList interface used
          ++ lib.optional (unused != [ ]) "- not connected: ${concatStringsSep ", " unused}"
          ++ lib.optionals (services != { }) ([ "Services:" ] ++ mapAttrsToList service services)
        );
    in
    concatStringsSep "\n\n" (
      [
        "# Homelab map"
        "Generated from the deployed NixOS configs (nix-topology). Hosts reach each other over the NetBird mesh as <host>.netbird.cloud; web services are https://<name>.gatica.one, reachable only over NetBird."
        (
          "## Networks\n"
          + concatStringsSep "\n" (
            mapAttrsToList (id: nw: "- ${nw.name} (${id}): ${nw.cidrv4 or "?"}") networks
          )
        )
        "## Nodes"
      ]
      ++ mapAttrsToList node topology.nodes
    )
    + "\n";
in
{
  imports = [ inputs.nix-topology.flakeModule ];

  flake.modules.nixos.base = {
    imports = [ inputs.nix-topology.nixosModules.default ];
  };

  # The agent's homelab_map tool reads this.
  flake.modules.nixos.agent =
    { pkgs, ... }:
    {
      agent.topologyFile = pkgs.writeText "homelab-map.md" (
        render config.flake.topology.x86_64-linux.config
      );
    };

  perSystem = {
    topology.modules = [
      (
        { config, ... }:
        let
          inherit (config.lib.topology) mkRouter mkConnection;
        in
        {
          networks.home = {
            name = "Home LAN";
            cidrv4 = "10.77.10.0/24";
          };
          networks.netbird = {
            name = "NetBird mesh";
            cidrv4 = "100.94.0.0/16";
          };

          # The home router: DHCP and the way out. Addresses on the LAN come from it (not fixed).
          nodes.router = mkRouter "Router" {
            info = "Home router, 10.77.10.1";
            interfaceGroups = [ [ "lan" ] ];
            interfaces.lan = {
              network = "home";
              addresses = [ "10.77.10.1" ];
            };
          };

          nodes.lugh.interfaces = {
            enp4s0 = {
              network = "home";
              addresses = [ "10.77.10.225" ];
              physicalConnections = [ (mkConnection "router" "lan") ];
            };
            nb-wt0 = {
              network = "netbird";
              virtual = true;
              addresses = [ "100.94.36.6" ];
            };
          };
          nodes.nabu.interfaces = {
            enp179s0f1 = {
              network = "home";
              addresses = [ "10.77.10.138" ];
              physicalConnections = [ (mkConnection "router" "lan") ];
            };
            nb-wt0 = {
              network = "netbird";
              virtual = true;
              addresses = [ "100.94.123.249" ];
            };
          };
          nodes.tenjin.interfaces = {
            wlp1s0 = {
              network = "home";
              type = "wifi";
              addresses = [ "10.77.10.189 (Wi-Fi)" ];
              physicalConnections = [ (mkConnection "router" "lan") ];
            };
            nb-wt0 = {
              network = "netbird";
              virtual = true;
              addresses = [ "100.94.61.153" ];
            };
          };
        }
      )
    ];
  };
}
