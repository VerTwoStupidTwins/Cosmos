# modules/gpu/nvidia.nix
#
# NVIDIA's driver and CUDA for compute. A host imports nixos.gpu-nvidia and lists its cards' compute capabilities;
# the driver branch, kernel module and CUDA release follow from them:
#
#   gpu.nvidia.cudaCapabilities = [ "6.0" ];  # Tesla P100
#
# Modules that build CUDA software take the toolkit from config.gpu.nvidia.cudaPackages, which is built for those
# capabilities only.
{
  flake.modules.nixos.gpu-nvidia =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.gpu.nvidia;

      # Cards before Turing (7.5) lost support after the 580 driver branch and CUDA 12, and NVIDIA's open kernel
      # module never ran on them.
      legacy = lib.any (cap: lib.versionOlder cap "7.5") cfg.cudaCapabilities;
    in
    {
      # Loaded once however many modules import it: the host, and the llama.cpp backend that needs this stack.
      key = "cosmos#gpu-nvidia";

      options.gpu.nvidia = {
        cudaCapabilities = lib.mkOption {
          type = lib.types.nonEmptyListOf lib.types.str;
          example = [
            "6.0"
            "8.6"
          ];
          description = ''
            Compute capabilities of the host's NVIDIA cards, as NVIDIA lists them (6.0 for a Tesla P100, 8.6 for
            an RTX 3090). CUDA software is compiled for these alone, which keeps builds smaller and quicker.
          '';
        };

        driver = lib.mkOption {
          type = lib.types.package;
          default =
            if legacy then
              config.boot.kernelPackages.nvidiaPackages.legacy_580
            else
              config.boot.kernelPackages.nvidiaPackages.production;
          defaultText = lib.literalMD "the 580 legacy branch for cards older than Turing, the production branch otherwise";
          description = "The NVIDIA driver. Its kernel module is compiled against the host's kernel.";
        };

        open = lib.mkOption {
          type = lib.types.bool;
          default = !legacy;
          defaultText = lib.literalMD "`true` from Turing on";
          description = "Whether to use NVIDIA's open kernel module, which needs a Turing or newer card.";
        };

        cudaPackages = lib.mkOption {
          type = lib.types.attrs;
          default = if legacy then pkgs.cudaPackages_12_9 else pkgs.cudaPackages;
          defaultText = lib.literalMD "CUDA 12.9 for cards older than Turing, nixpkgs' default CUDA otherwise";
          description = "The CUDA package set that CUDA software on this host is built with.";
        };

        powerLimits = lib.mkOption {
          type = lib.types.attrsOf lib.types.ints.positive;
          default = { };
          example = {
            "0000:20:00.0" = 200;
          };
          description = ''
            Power limits in watts, by PCI address (`lspci -D`), which stays put across boots while card numbers
            don't. `nvidia-smi -q -d POWER` shows the range each card accepts.
          '';
        };
      };

      config = {
        nixpkgs.config.cudaCapabilities = cfg.cudaCapabilities;

        # The NixOS NVIDIA module keys off this list even on a host without a display server.
        services.xserver.videoDrivers = [ "nvidia" ];

        hardware.graphics.enable = true;
        hardware.nvidia = {
          package = cfg.driver;
          inherit (cfg) open;
          # Keeps the cards initialised between jobs. Without a display holding them open, the driver tears its
          # state down whenever the last program exits, and the next one waits for it to come back up.
          nvidiaPersistenced = true;
        };

        environment.systemPackages = [
          pkgs.nvtopPackages.full
          pkgs.pciutils
          pkgs.vulkan-tools
          # deviceQuery and bandwidthTest, to check that CUDA reaches each card. The package keeps them in
          # demo_suite/ rather than bin/.
          (pkgs.runCommand "cuda-demo-suite" { } ''
            mkdir -p $out/bin
            for tool in deviceQuery bandwidthTest busGrind vectorAdd; do
              ln -s ${cfg.cudaPackages.cuda_demo_suite}/demo_suite/$tool $out/bin/$tool
            done
          '')
        ];

        # The driver forgets limits when it unloads, so they're set at each boot, once nvidia-persistenced holds the
        # cards. The closed driver has no hwmon interface, so this goes through nvidia-smi.
        systemd.services.gpu-power-limits-nvidia = lib.mkIf (cfg.powerLimits != { }) {
          description = "Set the NVIDIA cards' power limits";
          wantedBy = [ "multi-user.target" ];
          after = [ "nvidia-persistenced.service" ];
          wants = [ "nvidia-persistenced.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = lib.concatStrings (
            lib.mapAttrsToList (address: watts: ''
              ${lib.getExe' cfg.driver.bin "nvidia-smi"} -i ${address} -pl ${toString watts}
            '') cfg.powerLimits
          );
        };
      };
    };
}
