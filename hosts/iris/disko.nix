{ ... }:

{
  disko.devices = {
    disk.main = {
      type = "disk";

      # ASUS internal SSD, verified from the live installer on 2026-11-04.
      # The Samsung Type-C installer is a separate /dev/sda device.
      device = "/dev/disk/by-id/nvme-Samsung_SSD_990_EVO_Plus_1TB_S7U5NJ0XB13418V";

      content = {
        type = "gpt";
        partitions = {
          ESP = {
            priority = 1;
            size = "2G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };

          cryptroot = {
            priority = 2;
            size = "100%";
            content = {
              type = "luks";
              name = "cryptroot";
              # Match Kawiil's installation flow: Disko prompts for the LUKS
              # passphrase while formatting instead of reading a key file.
              askPassword = true;
              extraFormatArgs = [
                "--type"
                "luks2"
                "--pbkdf"
                "argon2id"
              ];
              settings.allowDiscards = true;

              content = {
                type = "lvm_pv";
                vg = "iris";
              };
            };
          };
        };
      };
    };

    # Keep both the hibernation image and the filesystem inside the same
    # encrypted LUKS container. The fixed-size swap LV is created first;
    # Bcachefs receives all remaining extents.
    lvm_vg.iris = {
      type = "lvm_vg";
      lvs = {
        swap = {
          size = "16G";
          content = {
            type = "swap";
            discardPolicy = "both";
            resumeDevice = true;
          };
        };

        system = {
          size = "100%";
          content = {
            type = "bcachefs";
            filesystem = "main";
            label = "iris.ssd";
          };
        };
      };
    };

    bcachefs_filesystems.main = {
      type = "bcachefs_filesystem";
      extraFormatArgs = [
        "--compression=zstd:1"
        "--background_compression=zstd:6"
        "--data_checksum=crc32c"
        "--metadata_checksum=crc32c"
        "--data_replicas=1"
        "--metadata_replicas=1"
      ];
      mountOptions = [ "noatime" ];
      subvolumes = {
        root.mountpoint = "/";
        home.mountpoint = "/home";
        nix.mountpoint = "/nix";
        games.mountpoint = "/games";
        snapshots.mountpoint = "/.snapshots";
      };
    };
  };
}
