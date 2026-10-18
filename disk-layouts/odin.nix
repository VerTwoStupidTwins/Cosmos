# Fresh installation ONLY: destroys the identified Odin NVMe, not the USB ISO.
# Verify model, serial, capacity, and whole-disk by-id path before running Disko.
{
  disko.devices = {
    disk.system = {
      type = "disk";
      device = "/dev/disk/by-id/nvme-addlink_M.2_PCIE_G5x4_NVMe_A4D01953036200206341";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          swap = {
            size = "4G";
            content.type = "swap";
          };
          root = {
            size = "100%";
            content = {
              type = "bcachefs";
              filesystem = "odin-root";
              label = "odin-root";
            };
          };
        };
      };
    };

    bcachefs_filesystems."odin-root" = {
      type = "bcachefs_filesystem";
      mountpoint = "/";
      mountOptions = [ "noatime" ];
      extraFormatArgs = [ "--compression=zstd" ];
    };
  };
}
