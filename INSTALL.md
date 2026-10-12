# Thoth installation, recovery, and updates

This guide is for the Lenovo ThinkPad T490 (`thoth`), NixOS 26.05, LUKS2-encrypted LVM (Bcachefs root plus 32 GiB hibernation swap), and Niri. Installer commands use Bash syntax (the default shell in the minimal live environment). Post-install examples for the Fish shell are identified where needed.

**Already installed and booting?** Follow [Routine updates](#routine-updates-on-the-running-system). Do **not** rerun Disko to apply normal configuration changes.

## Repository and machine-specific files

Cosmos is maintained at [VerTwoStupidTwins/Cosmos](https://github.com/VerTwoStupidTwins/Cosmos). On the running Thoth system, the working checkout lives at `/Cosmos`.

`flake.lock` and `hardware/thoth/facter.json` are already tracked in Git. The latter was generated from the actual T490 and is selected by `modules/hosts/thoth.nix`. Do not replace it with another machine's report.

For the reinstall, check out the **storage migration branch** rather than `main` (which still describes the running, non-LVM disk). Use HTTPS in the live installer:

```fish
git clone --branch reinstall/thoth-encrypted-lvm-hibernation --single-branch https://github.com/VerTwoStupidTwins/Cosmos.git
cd Cosmos
git branch --show-current
git status --short
```

The repository is public and the report may expose hardware identifiers. Never commit credentials, private keys, recovery codes, or LUKS key material.

## Routine updates on the running system

This does **not** repartition or format the disk:

```fish
cd /Cosmos
git status --short
git pull --ff-only
nix eval --raw '.#nixosConfigurations.thoth.config.system.build.toplevel.drvPath'
```

Review the Git diff before switching the active NixOS configuration:

```fish
sudo nixos-rebuild switch --flake /Cosmos#thoth
```

An evaluation succeeds only if the Nix expressions evaluate; it is not a substitute for a successful build or boot. Changes limited to Markdown documentation do not require a rebuild.

## Fresh installation only: destructive disk operations

**WARNING: Disko with `--mode destroy,format,mount` erases data on the target disk.** The Thoth layout targets:

```text
/dev/disk/by-id/nvme-eui.00080d030011aa76
```

It creates a 2 GiB FAT32 EFI system partition and a LUKS2 container holding LVM volume group `nixos`, with logical volumes `swap` (32 GiB) and Bcachefs `root` (remaining space). This layout is designed for 16 GiB RAM today and 24 GiB after the SODIMM upgrade. It must never be applied blindly to an existing installation. Verify the device resolves to the internal NVMe, not a USB installer. This **erases all existing partitions and data**. If there is anything to keep, back it up before continuing; for an explicitly disposable fresh installation, no backup is required. **Do not run `nixos-rebuild switch` with this new storage layout on the existing installation**: the generated device and resume paths do not match the currently installed partitions.

### 1. Boot an appropriate NixOS installer in UEFI mode

Before attempting formatting:

```fish
lsblk -d -o NAME,SIZE,MODEL,TRAN
readlink -f /dev/disk/by-id/nvme-eui.00080d030011aa76
test -d /sys/firmware/efi && echo 'UEFI mode: yes'
sudo modprobe bcachefs
grep -w bcachefs /proc/filesystems
```

Stop if the device differs from the internal T490 NVMe, UEFI is unavailable, or the installer kernel cannot mount Bcachefs. Installing only `bcachefs-tools` does not add a missing kernel module.

### 2. Verify the flake before modifying storage

```fish
nix flake show
nix eval --raw '.#nixosConfigurations.thoth.config.networking.hostName'
nix eval --raw '.#nixosConfigurations.thoth.config.disko.devices.disk.main.device'
nix eval --raw '.#nixosConfigurations.thoth.config.fileSystems."/".fsType'
nix eval --raw '.#nixosConfigurations.thoth.config.fileSystems."/".device'
nix eval --raw '.#nixosConfigurations.thoth.config.boot.resumeDevice'
nix eval --json --apply 'map (swap: { device = swap.device; randomEncryption = swap.randomEncryption.enable; })' '.#nixosConfigurations.thoth.config.swapDevices'
nix eval --json '.#nixosConfigurations.thoth.config.boot.initrd.services.lvm.enable'
nix eval --json '.#nixosConfigurations.thoth.config.programs.niri.enable'
nix eval --raw '.#nixosConfigurations.thoth.config.system.build.toplevel.drvPath'
```

The swap check deliberately selects only defined attributes. Evaluating the entire `swapDevices` list as JSON can fail on optional NixOS fields such as `label` that have no configured value.

Expected values include `thoth`, the pinned NVMe path, `bcachefs`, a Bcachefs UUID-based root device, `/dev/nixos/swap` for resume, a matching swap device, `true` for LVM initrd and Niri, and a derivation path. A successful evaluation does not prove the full system builds or boots.

### 3. Inspect the pinned Disko plan

The flake exposes the pinned Disko tool as `.#disko`:

```fish
nix run .#disko -- --mode destroy,format,mount --flake .#thoth --dry-run
```

In the pinned Disko revision, `--dry-run` prints the path to the generated script instead of executing it. Inspect that script and confirm the target disk before proceeding.

**Only if this is an intentionally destructive fresh installation**, after confirming the disk is correct and no data needs to be preserved:

```fish
nix run .#disko -- --mode destroy,format,mount --flake .#thoth
```

Set and retain the LUKS passphrase. Never use this command for a routine NixOS rebuild.

### 4. Check mounts, install, and set the user password

```fish
lsblk -f
cryptsetup status cryptroot
sudo pvs
sudo vgs
sudo lvs
sudo blkid /dev/nixos/swap /dev/nixos/root
findmnt /mnt
findmnt /mnt/boot
df -h /mnt/boot /mnt
```

Confirm Bcachefs LV `root` at `/mnt`, persistent swap LV `swap` (32 GiB), and a roughly 2 GiB FAT32 ESP at `/mnt/boot`. Verify `swapon --show` before installing. There is no ZFS pool or dedicated `/persist`.

```fish
sudo nixos-install \
  --root /mnt \
  --flake "$PWD#thoth" \
  --no-root-passwd \
  --max-jobs 1 \
  --cores 1
```

After installation, set the `twins` account password from the installer:

```fish
sudo nixos-enter --root /mnt -c 'passwd twins'
ls /mnt/boot/loader/entries
ls /mnt/boot/EFI/systemd
```

After installation, copy the verified live-environment checkout into the newly installed root with `sudo cp -a "$PWD" /mnt/Cosmos`. After reboot, run `sudo chown -R twins:users /Cosmos` so the normal user can maintain the repository. The installer checkout does not automatically persist. Reboot only after installation succeeds, boot entries exist, and the user password is set.

## First boot and service checks

Log in through SDDM to Niri. You can verify the system configuration and important services using:

```fish
cd /Cosmos
systemctl --user status lxqt-policykit-agent.service
systemctl status netbird-wt0.service
ip link show wt0
ssh -G github.com | rg -i '^identityagent '
set -gx SSH_AUTH_SOCK "$HOME/.1password/agent.sock"
ssh-add -l
```

The 1Password GUI must be running and its **Settings → Developer → Use the SSH agent** option enabled. If `ssh-add` says `Connection refused`, check the 1Password app and whether the socket has a listener. The LXQt Polkit user service should be active in the graphical session.

NetBird service startup does not itself prove enrollment or peer access; establish and test NetBird connectivity before restricting SSH exposure. In the current configuration, OpenSSH still opens its firewall port broadly.

## Hibernation test after first boot

Before testing, verify the encrypted LVM layout and resume configuration:

```fish
lsblk -f
sudo lvs
swapon --show
cat /sys/power/state
cat /sys/power/disk
nix eval --raw /Cosmos#nixosConfigurations.thoth.config.boot.resumeDevice
```

Back up unsaved work, connect reliable AC power for early testing, and confirm that the
kernel advertises `disk` in `/sys/power/state`. Initiate one controlled test with
`sudo systemctl hibernate`; then power on and verify that the previous session resumes.
Test again after the 24 GiB memory upgrade. Firmware and device-driver behavior can
prevent successful hibernation even when swap and NixOS settings evaluate.

Do not enable automated hibernation on lid close until multiple manual tests pass.

## Troubleshooting

When booting fails, determine whether the failure occurs at the bootloader, LUKS prompt, Bcachefs mount, userspace, SDDM, or Niri. Capture the exact error and relevant logs before changing storage. **Do not erase and reinstall simply because a NixOS switch or desktop service failed.**

For module changes, confirm evaluation first and use `sudo nixos-rebuild switch --flake /Cosmos#thoth` only after reviewing the changes. For physical disk repair or recovery, verify the target device again before any destructive operation.
