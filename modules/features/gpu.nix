# modules/features/gpu.nix
{
  flake.modules.nixos.gpu =
    { lib, pkgs, ... }:
    let
      # Watts, matched by PCI ID because card numbers change when a GPU is added.
      powerLimits = {
        "0x1002:0x744c" = 231; # RX 7900 XT: the lowest value it accepts
        "0x8086:0xe212" = 60; # Arc Pro B50
        "0x8086:0xe20b" = 130; # Arc B580
      };

      powerLimitCases = lib.concatStrings (
        lib.mapAttrsToList (id: watts: ''
          ${id}) watts=${toString watts} ;;
        '') powerLimits
      );
    in
    {
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
