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
      netbird = config.cosmos.netbird;
      groupsOf =
        name:
        lib.attrNames (
          filterAttrs (_: g: lib.elem name (if g.members != null then g.members else g.known)) netbird.groups
        );
      ports =
        p:
        "${lib.toUpper p.protocol} ${if p.ports == [ ] then "all ports" else concatStringsSep "," p.ports}";
      reachedBy =
        name:
        let
          mine = groupsOf name;
        in
        mapAttrsToList (pn: p: "${concatStringsSep "," p.from} (${pn}: ${ports p})") (
          filterAttrs (_: p: lib.any (g: lib.elem g mine) p.to) netbird.policies
        );
      policy =
        name: p:
        "- ${name}: ${concatStringsSep "," p.from} ${
          if p.bidirectional then "<->" else "->"
        } ${concatStringsSep "," p.to}, ${ports p}. ${p.why}"
        + optionalString (p.broad != null) " (deliberately broad: ${p.broad})"
        + optionalString (p.owner != "owner") " (the ${p.owner}'s)";
      group =
        name: g:
        "- ${name}: ${if g.members != null then concatStringsSep ", " g.members else "members not tracked"}"
        + optionalString (g.description != "") " — ${g.description}";
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
          ++ lib.optional (groupsOf name != [ ]) "NetBird groups: ${concatStringsSep ", " (groupsOf name)}"
          ++ lib.optional (
            reachedBy name != [ ]
          ) "Reachable over NetBird by: ${concatStringsSep "; " (reachedBy name)}"
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
      ++ [
        (
          "## Access over NetBird\n"
          + "NetBird drops anything no policy allows, before the hosts' firewalls. Declared in modules/netbird-policies.nix; "
          + "the netbird_access tool shows the live settings, and its drift view compares them with these.\n\n"
          + "Policies:\n"
          + concatStringsSep "\n" (mapAttrsToList policy netbird.policies)
          + "\n\nGroups:\n"
          + concatStringsSep "\n" (mapAttrsToList group netbird.groups)
        )
      ]
    )
    + "\n";
in
{
  imports = [ inputs.nix-topology.flakeModule ];

  flake.modules.nixos.base = {
    imports = [ inputs.nix-topology.nixosModules.default ];
  };

  # The homelab map for Hermes, in its home (its SOUL.md points it there).
  flake.modules.nixos.hermes = {
    services.hermes-agent.hermesHomeFiles."homelab-map.md" =
      render config.flake.topology.x86_64-linux.config;
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

          # The NAS shared with the brother: not a NixOS host of this flake, so described here.
          nodes.hestia = config.lib.topology.mkDevice "hestia" {
            info = "Shared NAS (Fedora 45), the owner's and his brother's; NFS shares, reached over NetBird only";
            interfaceGroups = [ [ "nb-wt0" ] ];
            interfaces.nb-wt0 = {
              network = "netbird";
              virtual = true;
              addresses = [ "100.94.252.21" ];
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
