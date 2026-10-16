# Fresh installation ONLY: this Disko layout destroys BOTH selected disks.
# Verify both by-id targets on Argus against model, serial, and capacity.
# Never substitute /dev/sda or /dev/sdb based on enumeration order.
{
  disko.devices.disk = {
    system = {
      type = "disk";
      device = "/dev/disk/by-id/ata-GIGASTONE_SSD_128GB_GSTPDEGAAB25250706";
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
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
              mountOptions = [ "noatime" ];
            };
          };
        };
      };
    };
    media = {
      type = "disk";
      device = "/dev/disk/by-id/ata-ST4000VN008-2DR166_ZDHBZ39G";
      content = {
        type = "gpt";
        partitions.media = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/var/lib/frigate";
            # Keep SSH/NetBird available for repair if the HDD fails.
            # Frigate separately requires this mount and refuses SSD fallback.
            mountOptions = [
              "noatime"
              "nofail"
              "x-systemd.device-timeout=30s"
            ];
          };
        };
      };
    };
  };
}
