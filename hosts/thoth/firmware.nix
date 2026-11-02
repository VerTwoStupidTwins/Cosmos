{ pkgs, ... }:

{
  # A separate boot configuration for firmware maintenance.
  # The normal system does not inherit these settings.
  specialisation.firmware-maintenance.configuration = {
    boot.kernelParams = [ "iomem=relaxed" ];

    programs.nix-ld = {
      enable = true;
      libraries = with pkgs; [
        pciutils
        libusb1
      ];
    };
  };

  # Convenient command, available from the normal system
  # and the firmware-maintenance specialisation.
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "thoth-firmware-update";

      runtimeInputs = with pkgs; [
        bash
        curl
        coreutils
        dmidecode
        which
        gnutar
        gzip
        gnugrep
        gnused
        gawk
        kmod
        pciutils
        util-linux
      ];

      text = ''
        if [ "$(id -u)" -ne 0 ]; then
          echo "Run with: sudo thoth-firmware-update" >&2
          exit 1
        fi

        if ! grep -qw "iomem=relaxed" /proc/cmdline; then
          echo "Boot the firmware-maintenance specialisation first." >&2
          exit 1
        fi

        if [ ! -e /run/current-system/sw/share/nix-ld/lib/ld.so ]; then
          echo "nix-ld is unavailable. Boot firmware-maintenance." >&2
          exit 1
        fi

        sb_var="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"

        if [ -r "$sb_var" ]; then
          sb_state="$(od -An -tu1 -j4 -N1 "$sb_var" | tr -d '[:space:]')"
          if [ "$sb_state" = "1" ]; then
            echo "Disable UEFI Secure Boot before updating firmware." >&2
            exit 1
          fi
        fi

        export NIX_LD=/run/current-system/sw/share/nix-ld/lib/ld.so
        export NIX_LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib

        tmpdir="$(mktemp -d)"
        trap 'rm -rf -- "$tmpdir"' EXIT

        echo "Downloading the official MrChromebox firmware utility..."

        curl --fail --location --silent --show-error \
          --proto '=https' --tlsv1.2 \
          --output "$tmpdir/firmware-util.sh" \
          https://mrchromebox.tech/firmware-util.sh

        bash "$tmpdir/firmware-util.sh"
      '';
    })
  ];
}
