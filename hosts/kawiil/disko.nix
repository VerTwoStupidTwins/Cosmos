{ ... }:

let
  # Common mount flags for NVMe storage.
  #
  # noatime:  Avoid access-time writes.
  # lazytime: Defer nonessential timestamp updates.
  mountOptions = [
    "noatime"
    "lazytime"
  ];

  # Apply consistent mount options to each subvolume.
  mkSubvolume = mountpoint: {
    inherit mountpoint mountOptions;
  };

in
{
  disko.devices = {

    # ============================================================
    # Physical disk: Crucial P3 Plus 4 TB NVMe
    # ============================================================

    disk.main = {
      type = "disk";

      device = "/dev/disk/by-id/nvme-CT4000P3PSSD8_2311E6BC7F01";

      content = {
        type = "gpt";

        partitions = {

          # ------------------------------------------------------
          # EFI System Partition
          # ------------------------------------------------------

          ESP = {
            priority = 1;
            size = "4G";
            type = "EF00";

            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";

              mountOptions = [
                "umask=0077"
              ];
            };
          };

          # ------------------------------------------------------
          # Encrypted system partition
          # ------------------------------------------------------

          root = {
            priority = 2;
            size = "100%";

            content = {
              type = "luks";
              name = "cryptroot";

              # Prompt for an encryption passphrase during setup.
              askPassword = true;

              # Permit SSD discard/TRIM through LUKS2.
              settings.allowDiscards = true;

              content = {
                type = "bcachefs";
                filesystem = "rootfs";
                label = "kawiil-root";

                # Bcachefs device-level TRIM.
                extraFormatArgs = [
                  "--discard"
                ];
              };
            };
          };
        };
      };
    };

    # ============================================================
    # Bcachefs filesystem
    # ============================================================

    bcachefs_filesystems.rootfs = {
      type = "bcachefs_filesystem";

      # ----------------------------------------------------------
      # Filesystem optimization
      # ----------------------------------------------------------

      extraFormatArgs = [

        # Fast compression during foreground writes.
        "--compression=zstd:1"

        # Avoid background recompression competing with
        # Steam, Sunshine, and AI inference workloads.
        "--background_compression=none"

        # Detect data and metadata corruption.
        "--data_checksum=crc32c"
        "--metadata_checksum=crc32c"

        # Single physical NVMe: one copy of each.
        "--data_replicas=1"
        "--metadata_replicas=1"
      ];

      mountOptions = mountOptions;

      # ----------------------------------------------------------
      # Bcachefs subvolumes
      # ----------------------------------------------------------

      subvolumes = {

        # NixOS root filesystem
        "@root" = mkSubvolume "/";

        # User files, configuration, Steam client data
        "@home" = mkSubvolume "/home";

        # Nix store
        "@nix" = mkSubvolume "/nix";

        # Filesystem snapshots
        "@snapshots" = mkSubvolume "/.snapshots";

        # AI models, inference services, containers
        "@srv" = mkSubvolume "/srv";

        # Dedicated Steam game library
        "@games" = mkSubvolume "/games";

        # System logs
        "@log" = mkSubvolume "/var/log";
      };
    };
  };

  # Bcachefs uses its own continuous discard mechanism.
  # No periodic fstrim timer is configured here.
}
