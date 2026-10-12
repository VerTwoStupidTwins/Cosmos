# Fresh Thoth reinstall: LUKS2 with LVM root and persistent swap for hibernation.
# DESTRUCTIVE if applied using disko --mode destroy,format,mount.
# Verify the by-id target against the actual internal T490 NVMe before formatting.
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
                type = "lvm_pv";
                vg = "nixos";
              };
            };
          };
        };
      };
    };

    lvm_vg.nixos = {
      type = "lvm_vg";
      lvs = {
        # Fixed-size swap is created before the root LV that uses all free extents.
        # 32 GiB accommodates the planned 24 GiB RAM upgrade.
        swap = {
          size = "32G";
          content = {
            type = "swap";
            resumeDevice = true;
          };
        };
        root = {
          size = "100%";
          content = {
            type = "bcachefs";
            filesystem = "thoth-root";
            label = "thoth-root";
          };
        };
      };
    };

    bcachefs_filesystems."thoth-root" = {
      type = "bcachefs_filesystem";
      mountpoint = "/";
      mountOptions = [
        "noatime"
        "x-systemd.device-timeout=infinity"
      ];
      extraFormatArgs = [ "--compression=zstd" ];
    };
  };
}
