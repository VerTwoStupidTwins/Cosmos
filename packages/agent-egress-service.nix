# Common controller for UID-wide agent policies. Callers own rules and ordering.
{ pkgs, rules }:
{
  Type = "oneshot";
  RemainAfterExit = true;
  ExecStart = "${pkgs.nftables}/bin/nft --file ${rules}";
  # No ExecStop: stopping a controller must not release surviving UID processes.
  NoNewPrivileges = true;
  ProtectSystem = "strict";
  ProtectHome = true;
  CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
  RestrictAddressFamilies = [
    "AF_NETLINK"
    "AF_UNIX"
  ];
}
