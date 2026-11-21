{ inputs, ... }:
let
  mountOptions = [ "noatime" ];
in
{
  hosts.lugh = {
    imports = [ inputs.disko.nixosModules.disko ];

    # bcachefs inside LUKS, which the TPM unlocks at boot, so lugh comes back up on its own after a power cut.
    disko.devices = {
      disk.main = {
        type = "disk";
        device = "/dev/nvme0n1";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "5G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };

            luks = {
              size = "100%";
              content = {
                type = "luks";
                name = "cryptroot";
                settings = {
                  allowDiscards = true;
                  bypassWorkqueues = true;
                  crypttabExtraOpts = [ "tpm2-device=auto" ];
                };
                content = {
                  type = "bcachefs";
                  filesystem = "root";
                  label = "main.cryptroot";
                  # --force: the format wipes old signatures (the btrfs from the earlier install) instead of asking.
                  extraFormatArgs = [
                    "--discard"
                    "--force"
                  ];
                };
              };
            };
          };
        };
      };

      bcachefs_filesystems.root = {
        type = "bcachefs_filesystem";
        # Writes go out lz4-compressed, which costs almost nothing, and bcachefs recompresses them with zstd in the
        # background when the disk is idle.
        extraFormatArgs = [
          "--compression=lz4"
          "--background_compression=zstd"
        ];
        subvolumes = {
          "subvolumes/root" = {
            mountpoint = "/";
            inherit mountOptions;
          };
          "subvolumes/home" = {
            mountpoint = "/home";
            inherit mountOptions;
          };
          "subvolumes/nix" = {
            mountpoint = "/nix";
            inherit mountOptions;
          };
          # Games for streaming and the game servers' worlds, in their own subvolume so snapshots of the system
          # don't drag them along.
          "subvolumes/games" = {
            mountpoint = "/games";
            inherit mountOptions;
          };
        };
      };
    };
  };
}
