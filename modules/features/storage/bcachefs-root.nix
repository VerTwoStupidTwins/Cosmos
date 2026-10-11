# Bcachefs support is provided via nixpkgs and its matching kernel module.
# Ensure the installer kernel can mount Bcachefs before Disko is run.
{
  flake.modules.nixos."bcachefs-root" = {
    boot.supportedFilesystems = [ "bcachefs" ];
    boot.initrd.systemd.enable = true;
    zramSwap.enable = true;
  };
}
