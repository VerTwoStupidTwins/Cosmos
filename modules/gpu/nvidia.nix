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

        boardFan = lib.mkOption {
          default = null;
          description = ''
            A fan on a motherboard header that cools the cards, such as a passive card's shroud fan. The board can't
            read the cards' temperatures, so a service sets its speed from the hottest card's. It holds that card at
            targetTemp with the slowest speed that manages it: above, the fan speeds up in proportion to how far over
            it is; well below, it slows gradually down to minRpm; at maxTemp it goes straight to maxRpm. It reads the
            fan's actual speed back and adjusts the header's duty until they match, so the speeds hold for any fan.
          '';
          type = lib.types.nullOr (
            lib.types.submodule {
              options = {
                chip = lib.mkOption {
                  type = lib.types.str;
                  example = "nct6796";
                  description = "The fan controller's hwmon name (/sys/class/hwmon/hwmon*/name).";
                };
                header = lib.mkOption {
                  type = lib.types.ints.positive;
                  description = "The header's number: the N of fanN_input and pwmN.";
                };
                targetTemp = lib.mkOption {
                  type = lib.types.ints.positive;
                  default = 70;
                  description = "°C: the hottest card's temperature to hold under load.";
                };
                maxTemp = lib.mkOption {
                  type = lib.types.ints.positive;
                  default = 78;
                  description = "°C: at or above it, the fan runs at maxRpm at once. Keep it below the cards' slowdown temperature.";
                };
                minRpm = lib.mkOption {
                  type = lib.types.ints.positive;
                  description = "Its speed while the cards are cool; no lower than the fan's own minimum.";
                };
                maxRpm = lib.mkOption {
                  type = lib.types.ints.positive;
                  description = ''
                    Its fastest, used at maxTemp and when no temperature comes back. Keep it below what draws more
                    current than the header supplies.
                  '';
                };
              };
            }
          );
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

        # Every two seconds. Above targetTemp the target speed rises 50 rpm for each degree over; within 3 °C below it,
        # it holds; further below, it falls 50 rpm a step (1,500 a minute), so the fan settles at the speed the load
        # needs and doesn't hunt. The duty then moves towards whatever gives that speed. When the service stops, the
        # board's own curve takes over.
        systemd.services.gpu-board-fan = lib.mkIf (cfg.boardFan != null) {
          description = "Drive the cards' board fan from their temperatures";
          wantedBy = [ "multi-user.target" ];
          after = [ "nvidia-persistenced.service" ];
          wants = [ "nvidia-persistenced.service" ];
          serviceConfig = {
            Restart = "always";
            RestartSec = 5;
          };
          path = [ cfg.driver.bin ];
          script = with lib.mapAttrs (_: toString) cfg.boardFan; ''
            hwmon=$(dirname "$(grep -lx ${chip} /sys/class/hwmon/hwmon*/name)")
            pwm=$hwmon/pwm${header}
            tach=$hwmon/fan${header}_input
            mode=$(cat "''${pwm}_enable")
            trap 'echo "$mode" > "''${pwm}_enable"' EXIT
            duty=$(cat "$pwm")
            echo 1 > "''${pwm}_enable"
            target=${minRpm}
            stalled=0
            while true; do
              temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits | sort -n | tail -1) || temp=
              if ! [[ $temp =~ ^[0-9]+$ ]] || (( temp >= ${maxTemp} )); then
                target=${maxRpm}
              elif (( temp > ${targetTemp} )); then
                target=$(( target + (temp - ${targetTemp}) * 50 ))
              elif (( temp < ${targetTemp} - 3 )); then
                target=$(( target - 50 ))
              fi
              (( target < ${minRpm} )) && target=${minRpm}
              (( target > ${maxRpm} )) && target=${maxRpm}

              rpm=$(cat "$tach")
              # A step of the duty (0-255) for every 40 rpm off target, at most 16 at a time.
              step=$(( (target - rpm) / 40 ))
              (( step > 16 )) && step=16
              (( step < -16 )) && step=-16
              duty=$(( duty + step ))
              (( duty < 0 )) && duty=0
              (( duty > 255 )) && duty=255
              # With no speed reading it would climb to full duty, and if the fan were in fact spinning, draw more
              # than the header may supply; so it goes no higher than 100 (39%) until a reading comes back.
              if (( rpm == 0 )); then
                (( duty > 100 )) && duty=100
                (( ++stalled == 5 )) && echo "the fan reads 0 rpm at duty $duty/255: stopped, unplugged or no tach wire?"
              else
                stalled=0
              fi
              echo $duty > "$pwm"
              sleep 2
            done
          '';
        };
      };
    };
}
