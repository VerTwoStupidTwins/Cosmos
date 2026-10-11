# Install Thoth: T490 / NixOS 26.05 / native Bcachefs / Niri

This guide uses Fish syntax where shell-specific syntax matters.

**DESTRUCTIVE WARNING:** Disko's `destroy,format,mount` erases ALL data on the
**Toshiba 512 GB NVMe** selected by the pinned by-id path. The **Kioxia
Ventoy installer USB (`/dev/sda`) must remain untouched**. Do not rerun Disko
if the disk is already formatted and you only changed packages or Niri.

## 1. Prepare the full repository

Extract the ZIP into a directory. For your already-pushed Cosmos repo, we
recommend making a **new Git branch** and copying the replacement source tree
into that checkout. Back up local-only changes first. For example:

```fish
git clone https://codeberg.org/TwoStupidTwins/Cosmos.git
cd Cosmos
git switch -c thoth-bcachefs-niri
# Replace /path/to with the directory holding the unzipped release.
rm -rf modules disk-layouts
cp -a /path/to/Cosmos-T490-Bcachefs-Niri/. .
```

This deliberately removes the obsolete ZFS and Preservation modules, which
`import-tree` would otherwise discover even if you don't explicitly import
them. It **does not delete `.git`, the old `flake.lock`, or the T490 report**.
If you're not working in a Git checkout, use the extracted directory directly
and omit Git-only commands below.

You must restore `hardware/thoth/facter.json` from the original Cosmos repo,
or generate it from the **T490** while running the installer:

```fish
set -gx NIX_CONFIG 'experimental-features = nix-command flakes'
# cd /path/to/Cosmos-T490-Bcachefs-Niri
sudo nix run nixpkgs#nixos-facter -- -o hardware/thoth/facter.json
```

If already present in your old Cosmos checkout, **copy that report instead**.
Never use the older Dragonfly Chromebook's Facter report. Stage all files if
working inside a Git clone, since flakes only see tracked/staged files there:

```fish
# Only run git add if this directory is a Git checkout.
git add -A
nix flake lock
git add flake.lock
```

The ZIP does not contain a `flake.lock`. If you apply it to the original
Cosmos Git checkout, the **existing** lockfile survives, and `nix flake lock`
updates it to match this flake. If you work in a new extracted directory, Nix
creates a new lockfile. Inspect the lockfile before deployment. Note that
Facter reports can reveal hardware identifiers: review the report before
pushing it to a public repository.

## 2. Non-destructive firmware, kernel and disk checks

Boot the NixOS **26.05** installer in UEFI mode, then check:

```fish
free -h
lsblk -d -o NAME,SIZE,MODEL,TRAN
readlink -f /dev/disk/by-id/nvme-eui.00080d030011aa76
test -d /sys/firmware/efi; and echo 'UEFI mode: yes'
sudo modprobe bcachefs
grep -w bcachefs /proc/filesystems
```

Verify the by-id link resolves to the **Toshiba internal NVMe** and not the
Ventoy USB. **Stop before Disko** if `modprobe bcachefs` fails or Bcachefs is
absent from `/proc/filesystems`: the installer cannot mount your root. Installing
only `bcachefs-tools` does not supply a missing kernel module. The NixOS
system will likewise need a Bcachefs-compatible kernel and module closure.

## 3. Evaluate the actual merged flake

```fish
nix flake show
nix eval --raw '.#nixosConfigurations.thoth.config.networking.hostName'
nix eval --raw '.#nixosConfigurations.thoth.config.disko.devices.disk.main.device'
nix eval --raw '.#nixosConfigurations.thoth.config.disko.devices.disk.main.content.partitions.encrypted.content.content.type'
nix eval --raw '.#nixosConfigurations.thoth.config.disko.devices.bcachefs_filesystems."thoth-root".type'
nix eval --raw '.#nixosConfigurations.thoth.config.fileSystems."/".fsType'
nix eval --raw '.#nixosConfigurations.thoth.config.fileSystems."/".device'
nix eval --json '.#nixosConfigurations.thoth.config.programs.niri.enable'
nix eval --json '.#nixosConfigurations.thoth.config.services.displayManager.sddm.enable'
nix eval --raw '.#nixosConfigurations.thoth.config.system.build.toplevel.drvPath'
```

Expected in order: `thoth`, the specified Toshiba by-id device, `bcachefs`,
`bcachefs_filesystem`, `bcachefs`, `/dev/mapper/cryptroot`, `true`, `true`,
and a Nix store `.drv` path. The final evaluation must succeed **before any
formatting**. It does not prove the whole system can build or boot.

For the Niri/CLI package list, you can evaluate
`config.environment.systemPackages` using `nix eval`, or try `nix build
--dry-run --no-link '.#nixosConfigurations.thoth.config.system.build.toplevel'`.
A dry run does not compile anything and is not a real build test.

## 4. Prepare for Disko

If this is a retry from a failed previous install, a clean reboot into the
installer is preferred. Verify no old ZFS pool remains imported and no target
mounts or LUKS mapper are active. If any are, **stop and cleanly unmount,
export and close them first** before touching partitions.

Run the Disko version pinned by the flake using the `.#disko` wrapper:

```fish
nix run .#disko -- --mode destroy,format,mount --flake .#thoth --dry-run
```

This is **not** a complete preview of the bash contents: it outputs the path
to the generated script. You can inspect the path manually if desired.

If all checks pass, and you intentionally accept losing everything on the
Toshiba NVMe, run the **destructive** command:

```fish
nix run .#disko -- --mode destroy,format,mount --flake .#thoth
```

Use a LUKS password you'll remember. **Do not bypass the disk safety prompt.**

## 5. Verify before installing NixOS

```fish
lsblk -f
cryptsetup status cryptroot
findmnt /mnt
findmnt /mnt/boot
df -h /mnt/boot /mnt
```

Expect the decrypted Bcachefs root mounted at `/mnt`, FAT32 at `/mnt/boot`,
and approximately 2 GiB EFI capacity. The boot partition was erroneously
~196 MiB in one earlier installation attempt; do not continue if that
recurs. There is no `/persist`, no ZFS, and no blank root snapshot.

## 6. Install NixOS with Niri enabled

From the extracted/replaced Cosmos repository directory:

```fish
sudo nixos-install \
  --root /mnt \
  --flake "$PWD#thoth" \
  --no-root-passwd \
  --max-jobs 1 \
  --cores 1
```

**Fish note:** `"$PWD#thoth"` uses your current directory. Alternatively,
use the full literal path such as `/home/nixos/Cosmos#thoth`.

A full desktop plus the external Bcachefs module can still need compilation;
extra RAM and build-job limits reduce risk but do not guarantee success.

After a successful install, set the persistent user password:

```fish
sudo nixos-enter --root /mnt -c 'passwd twins'
```

Check the bootloader:

```fish
ls /mnt/boot/loader/entries
ls /mnt/boot/EFI/systemd
```

Do not reboot until the install succeeded, `twins` has a working password and
boot entries exist. Boot into SDDM, select Niri, and log in. Alacritty and
Fuzzel are present for the upstream default keybindings. Wofi, Kitty and the
other selected packages are installed but have no custom keybindings.

## 7. Keep Cosmos in your home after first boot

```fish
cd ~
git clone https://codeberg.org/TwoStupidTwins/Cosmos.git
```

You should commit/push the **revised branch** to Codeberg before this step;
otherwise a fresh clone will still contain the old ZFS-era configuration.

## Troubleshooting

If first boot fails, identify the exact boundary: bootloader, LUKS prompt,
Bcachefs mount, userspace, SDDM or Niri. Record the error and logs before
erasing the disk again. The previous failed install was never fully diagnosed,
and a change of filesystem alone is not proof of a fix.
