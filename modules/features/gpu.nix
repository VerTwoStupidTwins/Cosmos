# modules/features/gpu.nix
{
  flake.modules.nixos.gpu =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      # Power limits in watts. Cards are matched by PCI ID because card numbers change when a GPU is added.
      powerLimits = {
        "7900 XT" = 231; # the lowest value it accepts
        "Pro B50" = 60;
        "B580" = 130;
      };

      powerLimitCases = lib.concatStrings (
        lib.mapAttrsToList (card: watts: ''
          ${config.monitor.cards.${card}.pciId}) watts=${toString watts} ;;
        '') powerLimits
      );
    in
    {
      monitor.cards = {
        "7900 XT" = {
          name = "RX 7900 XT";
          pciId = "0x1002:0x744c";
        };
        "B580" = {
          name = "Arc B580";
          pciId = "0x8086:0xe20b";
          note = "The helper also picks out memories after each chat turn. ComfyUI borrows the card from it for each image.";
        };
        "Pro B50" = {
          name = "Arc Pro B50";
          pciId = "0x8086:0xe212";
          note = "The approval model answers through the decision model.";
        };
      };

      hardware.graphics.enable = true;
      environment.systemPackages = with pkgs; [
        vulkan-tools
        nvtopPackages.full
        pciutils
      ];

      systemd.services.gpu-power-limits = {
        description = "Keep the GPUs within the power supply's budget";
        wantedBy = [ "multi-user.target" ];
        before = [ "llama-swap.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          status=0

          for device in /sys/bus/pci/devices/*; do
            case "$(cat "$device/vendor"):$(cat "$device/device")" in
              ${powerLimitCases}
              *) continue ;;
            esac

            # The driver may still be starting when this runs.
            for _ in {1..30}; do
              cap=$(echo "$device"/hwmon/hwmon*/power1_cap)
              [ -f "$cap" ] && break
              sleep 1
            done

            microwatts=$((watts * 1000000))
            if [ -f "$cap" ] && echo "$microwatts" > "$cap" && [ "$(cat "$cap")" = "$microwatts" ]; then
              echo "$device: limited to $watts W"
            else
              echo "$device: could not set a $watts W limit" >&2
              status=1
            fi
          done

          exit "$status"
        '';
      };
    };
}
