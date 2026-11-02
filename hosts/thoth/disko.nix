{ ... }:
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/disk/by-id/nvme-SHGP31-500GM_FJB9N514511509A4V";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
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
            size = "100%";
            content = {
              type = "luks";
              name = "cryptroot";
              extraFormatArgs = [ "--type" "luks2" "--pbkdf" "argon2id" ];
              settings.allowDiscards = true;
              content = {
                type = "bcachefs";
                filesystem = "main";
                # Mandatory for this pinned disko revision: avoid --label= (empty).
                label = "thoth.ssd";
              };
            };
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
