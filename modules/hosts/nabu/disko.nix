{ inputs, ... }:
let
  mountOptions = [ "noatime" ];
in
{
  hosts.nabu = {
    imports = [ inputs.disko.nixosModules.disko ];

    # No disk encryption: the board has no TPM to unlock it unattended, and nabu should come back up on its own
    # after a power cut.
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

            root = {
              size = "100%";
              content = {
                type = "bcachefs";
                filesystem = "root";
                label = "main.nvme0";
                # --force: the format wipes old signatures (a LUKS header from an earlier install) instead of asking.
                extraFormatArgs = [
                  "--discard"
                  "--force"
                ];
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
          # Model weights, in their own subvolume so snapshots of the system don't drag hundreds of GB along.
          "subvolumes/models" = {
            mountpoint = "/models";
            inherit mountOptions;
          };
        };
      };
    };
  };
}
