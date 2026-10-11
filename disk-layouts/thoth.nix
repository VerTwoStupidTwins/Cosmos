# Thoth: single-device Bcachefs on LUKS2 using Disko's native Bcachefs type.
# DESTRUCTIVE if applied using disko --mode destroy,format,mount.
# Disk is specific to Thoth. Verify /dev/disk/by-id resolves to the Toshiba NVMe.
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/disk/by-id/nvme-eui.00080d030011aa76";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "2G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              extraArgs = [
                "-F"
                "32"
              ];
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };

          encrypted = {
            size = "100%";
            content = {
              type = "luks";
              name = "cryptroot";
              initrdUnlock = true;
              settings.allowDiscards = true;
              content = {
                type = "bcachefs";
                filesystem = "thoth-root";
                label = "thoth-root";
              };
            };
          };
        };
      };
    };

    bcachefs_filesystems."thoth-root" = {
      type = "bcachefs_filesystem";
      mountpoint = "/";
      mountOptions = [ "noatime" ];
      extraFormatArgs = [ "--compression=zstd" ];
    };
  };
}
