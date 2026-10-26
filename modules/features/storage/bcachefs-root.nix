# Bcachefs support is provided via nixpkgs and its matching kernel module.
# Ensure the installer kernel can mount Bcachefs before Disko is run.
{
  flake.modules.nixos."bcachefs-root" = {
    boot.supportedFilesystems = [ "bcachefs" ];
    # Prefer disk-backed swap while first validating suspend-to-disk.
    zramSwap.enable = false;
  };
}
