{ inputs, ... }:
let
  mountOptions = [
    "compress=zstd:1"
    "noatime"
  ];
in
{
  hosts.thoth = {
    imports = [ inputs.disko.nixosModules.disko ];

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
            Luks = {
              size = "100%";
              content = {
                type = "luks";
                name = "cryptroot";
                settings = {
                  allowDiscards = true;
                  bypassWorkqueues = true;
                };
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
          swap = {
            size = "10G";
            content = {
              type = "swap";
              resumeDevice = true;
            };
          };
          root = {
            size = "100%FREE";
            content = {
              type = "btrfs";
              extraArgs = [ "-f" ];
              subvolumes = {
                "@" = {
                  mountpoint = "/";
                  inherit mountOptions;
                };
                "@home" = {
                  mountpoint = "/home";
                  inherit mountOptions;
                };
                "@snapshots" = {
                  mountpoint = "/home/.snapshots";
                  inherit mountOptions;
                };
                "@nix" = {
                  mountpoint = "/nix";
                  inherit mountOptions;
                };
                "@games" = {
                  mountpoint = "/games";
                  inherit mountOptions;
                };
              };
            };
          };
        };
      };
    };
  };
}
