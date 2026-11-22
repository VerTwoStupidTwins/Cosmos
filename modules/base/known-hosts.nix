# modules/base/known-hosts.nix
# Each host's SSH host key, so every host knows the others without trust-on-first-use. A host's key is also its sops
# identity: ssh-to-age turns it into the age key for that host in .sops.yaml, which is how to check a key here. A reinstall
# that makes a new key changes both.
{ config, lib, ... }:
let
  hostKeys = config.cosmos.hostKeys;
  peers = config.cosmos.netbird.peers;
in
{
  options.cosmos.hostKeys = lib.mkOption {
    description = "Each host's ed25519 SSH host key (/etc/ssh/ssh_host_ed25519_key.pub), without the comment.";
    type = lib.types.attrsOf lib.types.str;
  };

  config.cosmos.hostKeys = {
    lugh = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF3DM9wpr41MlWUe1+C05lht9vg1a9h1XNqFGBbw5oAU";
    nabu = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN0Rbun4edklZJ1+FXTYmOA/a+guYpFqYwal3HwZxgTd";
    tenjin = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOJF/cycor9+kykf4SVYNLraIPJ68HOsawS7ctmoB+eY";
  };

  # Under its short name, its NetBird name and its NetBird address.
  config.flake.modules.nixos.base.programs.ssh.knownHosts = lib.mapAttrs (host: key: {
    hostNames = [
      host
      "${host}.netbird.cloud"
    ]
    ++ lib.optional (peers ? ${host}) peers.${host}.ip;
    publicKey = key;
  }) hostKeys;
}
