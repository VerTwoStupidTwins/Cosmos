# Cosmos: Thoth on NixOS 26.05, Bcachefs + Niri

Rebuilt source tree for the Lenovo ThinkPad T490 (`thoth`). This consolidates
the previous Cosmos Bcachefs baseline and the latest T490-only Niri package
changes. The repository retains the **Dendritic Nix** module organization
(`flake-parts` + `import-tree`), NixOS Facter and Disko.

## What it configures

- NixOS 26.05, x86_64-linux, hostname `thoth`, user `twins` with Fish.
- GPT disk layout on the verified Toshiba NVMe by-id device: 2 GiB EFI/FAT32,
  the remainder LUKS2 with **one native-Disko Bcachefs filesystem** at `/`.
- Systemd initrd with a root device of `/dev/mapper/cryptroot`, zram swap.
- **Persistent system**: no ZFS, Preservation, Impermanence, root rollback,
  snapshots, dedicated `/persist`, or predefined password-hash secrets.
- Niri + SDDM from the first boot, with hardware graphics, PipeWire,
  Bluetooth, Polkit and a basic PAM entry for the lock screen.
- All previously selected workstation packages: see `PACKAGES.md`.
- **No custom Niri configuration**: no `config.kdl`, keybindings, autostarts,
  Waybar settings, wallpaper themes or Home Manager dotfiles.
- **No Chromebook convertible/tablet utilities**: no `wvkbd`,
  `iio-niri`, `iio-sensor-proxy`, tablet-mode units, screen rotation,
  or Chromebook-specific key remapping.

## Required machine-specific inputs

The original T490 `hardware/thoth/facter.json` cannot be recreated accurately
without the T490 or the original Cosmos repository. **It is intentionally not
included.** Restore it from your existing Cosmos checkout or regenerate it on
the actual T490 using `nixos-facter`. See `hardware/thoth/README.md`.

`flake.lock` is also intentionally absent. Generate it on the NixOS installer
(`nix flake lock`) or bring forward your existing lockfile and update it.
**Commit both before installing** if working inside a Git clone.

This source is ready to be checked, but is **not a verified bootable image**.
Evaluate the entire NixOS configuration and confirm the installer kernel can
load Bcachefs **before** executing any destructive Disko operation.

## Repository structure

```text
Cosmos-T490-Bcachefs-Niri/
├── flake.nix
├── disk-layouts/
│   └── thoth.nix               # Native Disko Bcachefs + LUKS2
├── hardware/
│   └── thoth/
│       └── README.md           # Add your actual facter.json here
├── modules/
│   ├── development.nix        # Formatter, dev shell, pinned Disko app
│   ├── features/
│   │   ├── base.nix
│   │   ├── cli-tools.nix
│   │   ├── workstation.nix
│   │   ├── desktop/
│   │   │   ├── niri.nix         # Desktop services and Wayland packages
│   │   │   └── apps.nix         # Additional workstation apps
│   │   └── storage/
│   │       └── bcachefs-root.nix
│   └── hosts/
│       └── thoth.nix          # Niri enabled on first boot
├── INSTALL.md
├── PACKAGES.md
└── README.md
```

The Home Manager flake input is reserved for future customization; it is **not
currently activated**, to avoid generating user-specific configuration before
the initial boot. The repository only declares `thoth`: other homelab hosts
require their own verified hardware and disk layouts.

## Quick verification (Fish shell)

```fish
set -gx NIX_CONFIG 'experimental-features = nix-command flakes'
# Restore hardware/thoth/facter.json first.
nix flake lock
nix flake show
nix eval --json '.#nixosConfigurations.thoth.config.programs.niri.enable'
nix eval --json '.#nixosConfigurations.thoth.config.services.displayManager.sddm.enable'
nix eval --raw '.#nixosConfigurations.thoth.config.fileSystems."/".fsType'
nix eval --raw '.#nixosConfigurations.thoth.config.fileSystems."/".device'
nix eval --raw '.#nixosConfigurations.thoth.config.system.build.toplevel.drvPath'
```

Read `INSTALL.md` for the full procedure and disk safety checks. **Do not run
Disko based on this README alone.**
