# Thoth: ThinkPad T490

This is the single host guide for [thoth.nix](thoth.nix). Repository structure and contributor rules live in [README.md](../../README.md) and [AGENTS.md](../../AGENTS.md). Commands below are procedures, not evidence that they have just been run. Agents need explicit permission for deployment, installation, disk changes, hardware-report regeneration, and power-state changes.

## Configuration and status

| Area | Declared configuration |
| --- | --- |
| System | NixOS 26.05, `x86_64-linux`, user `twins`, Fish |
| Storage | GPT, 2 GiB FAT32 ESP, LUKS container `cryptroot`, LVM VG `nixos` |
| Logical volumes | Bcachefs `root`, persistent 32 GiB `swap` |
| Boot/resume | systemd-boot, systemd initrd with LVM, `/dev/nixos/swap` |
| Desktop | Wayland SDDM, Niri, PipeWire, Bluetooth, LXQt Polkit |
| Network | NetworkManager, resolved, firewall, OpenSSH, NetBird `wt0` |
| Credentials | 1Password desktop/CLI and SSH agent |
| State | Persistent root; no ZFS, impermanence, or automatic root rollback |

Existing documentation records a completed encrypted-LVM reinstall and a successful manual hibernate/resume test restoring Niri. That historical test does not prove current runtime health or the timed suspend-to-hibernate transition. The layout accommodates the documented 16 GiB RAM and planned 24 GiB upgrade; repeat resume testing after hardware changes.

Sources of truth:

- [Host composition](thoth.nix): profiles, user, boot/resume settings, Hermes CLI/Desktop.
- [Disk layout](../../disk-layouts/thoth.nix): target device and generated filesystem/swap configuration.
- [Hardware report](../../hardware/thoth/facter.json): the tracked real T490 Facter report.
- [Base features](../features/base.nix), [CLI tools](../features/cli-tools.nix), and [workstation](../features/workstation.nix).
- [Niri](../features/desktop/niri.nix), [applications](../features/desktop/apps.nix), [Polkit agent](../features/desktop/polkit-agent.nix), and [1Password](../features/security/onepassword.nix).
- [Power policy](../features/power/laptop-sleep.nix), [NetBird](../features/netbird.nix), and [SSH](../features/ssh.nix).

## Packages, services, and session behavior

Use the Nix modules above as the authoritative package inventory rather than maintaining a second exhaustive list. Hermes CLI and Desktop are installed from the pinned Hermes flake, with no persistent gateway service declared; runtime authentication, sessions, and memory stay outside Git in `~/.hermes`.

Niri/SDDM, PipeWire ALSA/PulseAudio, RTKit, Polkit, Bluetooth, NetworkManager, GVfs, UDisks2, and Tumbler are enabled. The LXQt Polkit agent is a user service attached to `graphical-session.target`; `swayidle.service` is attached to `niri.service` and locks before sleep.

Optional packages do not necessarily autostart. Cosmos does not declare custom Niri `config.kdl`, keybindings, themes, Waybar styling, wallpaper selection, or user units for Waybar, Mako, awww, and clipboard utilities. Home Manager is not activated. Installing TLP, Flatpak, Podman, or GNOME Keyring does not mean their services/integrations are enabled. Clipse is the selected clipboard-history package and Crosspipe the included audio-routing application; do not assume alternatives are installed. Niri upstream defaults commonly use Super+T for Alacritty and Super+D for Fuzzel, but Cosmos does not declare those bindings itself.

NetBird's named client and interface are both `wt0`, with UDP port `58120`, autostart, hardened mode, and firewall options enabled. Startup alone does not prove enrollment or peer connectivity. OpenSSH uses `openFirewall = true` and is **not restricted to NetBird**. Establish and test NetBird access before tightening SSH exposure.

1Password provides SSH identities at `~/.1password/agent.sock`; the OpenSSH client sets `IdentityAgent` system-wide and the built-in SSH agent is disabled. The GUI must be running with Settings → Developer → Use the SSH agent enabled. A refused connection can mean the agent has no socket listener. Its unfree allowance is narrowly declared in the workstation security feature.

## Routine updates

Documentation-only changes do not require a rebuild. For merged configuration updates, start on a clean checkout, inspect incoming changes, and fast-forward local main; do not edit or commit on main. Work on topic branches follows AGENTS.md.

```fish
cd /Cosmos
git status --short
git fetch origin
git diff HEAD..origin/main
```

Stop if the tree is dirty. After reviewing the incoming changes:

```fish
git switch main
git pull --ff-only
nix eval --no-write-lock-file --raw '.#nixosConfigurations.thoth.config.system.build.toplevel.drvPath'
```

For a reviewed **non-storage configuration change**, only with explicit deployment permission:

```fish
sudo nixos-rebuild switch --flake /Cosmos#thoth
```

Routine switching does not invoke destructive Disko formatting. A storage migration is not a routine switch: confirm that generated device, filesystem, encryption, and resume paths match the actual installed layout. Successful evaluation is not proof of a successful build or boot.

## Fresh installation and recovery

**Already installed and booting? Do not run Disko formatting.** Do not erase/reinstall because a configuration switch or desktop service failed. Identify the failing stage (bootloader, LUKS unlock, Bcachefs mount, userspace, SDDM, or Niri), collect the exact error/logs, and diagnose first.

Installer examples use Bash; workstation examples elsewhere use Fish. Current main already contains the encrypted-LVM layout: the old migration-branch installation advice is obsolete. Clone the reviewed main revision over HTTPS in the live installer:

```bash
git clone --branch main --single-branch https://github.com/VerTwoStupidTwins/Cosmos.git
cd Cosmos
git branch --show-current
git status --short
git log -1 --oneline
```

### Verify the disk and installer

The [layout](../../disk-layouts/thoth.nix) targets `/dev/disk/by-id/nvme-eui.00080d030011aa76`. It creates the ESP and a LUKS-encrypted LVM PV, with VG `nixos`, 32 GiB LV `swap`, and Bcachefs LV `root` using the remaining space. **Formatting erases all partitions and data on that target.** Verify the disk resolves to the internal NVMe, not a USB installer. Back up anything to preserve; proceed only for an explicitly authorized, intentionally destructive installation.

```bash
lsblk -d -o NAME,SIZE,MODEL,TRAN
readlink -f /dev/disk/by-id/nvme-eui.00080d030011aa76
test -d /sys/firmware/efi && printf 'UEFI mode: yes\n'
sudo modprobe bcachefs
grep -w bcachefs /proc/filesystems
```

Stop if the disk differs, UEFI is unavailable, or the installer kernel cannot mount Bcachefs. Installing bcachefs-tools does not add a missing kernel module. Do not replace the committed hardware report with another machine's report.

### Evaluate before changing storage

```bash
nix eval --no-write-lock-file --raw '.#nixosConfigurations.thoth.config.networking.hostName'
nix eval --no-write-lock-file --raw '.#nixosConfigurations.thoth.config.disko.devices.disk.main.device'
nix eval --no-write-lock-file --raw '.#nixosConfigurations.thoth.config.fileSystems."/".fsType'
nix eval --no-write-lock-file --raw '.#nixosConfigurations.thoth.config.fileSystems."/".device'
nix eval --no-write-lock-file --raw '.#nixosConfigurations.thoth.config.boot.resumeDevice'
nix eval --no-write-lock-file --json --apply 'map (swap: { device = swap.device; randomEncryption = swap.randomEncryption.enable; })' '.#nixosConfigurations.thoth.config.swapDevices'
nix eval --no-write-lock-file --json '.#nixosConfigurations.thoth.config.boot.initrd.services.lvm.enable'
nix eval --no-write-lock-file --json '.#nixosConfigurations.thoth.config.programs.niri.enable'
nix eval --no-write-lock-file --raw '.#nixosConfigurations.thoth.config.system.build.toplevel.drvPath'
nix flake show --no-write-lock-file
```

Expect `thoth`, the pinned NVMe path, `bcachefs`, a Bcachefs UUID-based root device, `/dev/nixos/swap` for resume and swap, persistent rather than random-encrypted swap, and enabled LVM initrd/Niri. Select defined swap attributes: serializing the entire `swapDevices` list can fail on unset optional fields such as `label`. Evaluation does not prove the system builds or boots.

### Inspect the pinned Disko plan

Use Cosmos' pinned app, not an unrelated Disko revision:

```bash
nix run --no-write-lock-file .#disko -- --mode destroy,format,mount --flake .#thoth --dry-run
```

In the pinned revision, `--dry-run` prints a generated script path rather than executing it. Inspect the script and confirm the target. This is not permission to execute the destructive plan.

Only after explicit approval for a destructive fresh installation, verified device targeting, and backups of anything to preserve:

```bash
nix run --no-write-lock-file .#disko -- --mode destroy,format,mount --flake .#thoth
```

Set and retain the LUKS passphrase securely; never put it or recovery material in Git. Never use this command for routine updates.

### Verify mounts, install, and retain the checkout

```bash
lsblk -f
cryptsetup status cryptroot
sudo pvs
sudo vgs
sudo lvs
sudo blkid /dev/nixos/swap /dev/nixos/root
findmnt /mnt
findmnt /mnt/boot
df -h /mnt/boot /mnt
swapon --show
```

Confirm Bcachefs root at `/mnt`, persistent 32 GiB swap, and a roughly 2 GiB FAT32 ESP at `/mnt/boot`. There is no ZFS pool or dedicated `/persist`.

```bash
sudo nixos-install \
  --root /mnt \
  --flake "$PWD#thoth" \
  --no-root-passwd \
  --max-jobs 1 \
  --cores 1
sudo nixos-enter --root /mnt -c 'passwd twins'
ls /mnt/boot/loader/entries
ls /mnt/boot/EFI/systemd
sudo cp -a "$PWD" /mnt/Cosmos
```

The live-environment checkout does not persist automatically. After reboot, restore normal-user ownership with `sudo chown -R twins:users /Cosmos`. Reboot only after successful installation, verified boot entries, and a set user password; an agent must obtain reboot permission separately.

## First boot and service checks

Log in through SDDM to Niri, then inspect:

```fish
cd /Cosmos
systemctl --user status lxqt-policykit-agent.service
systemctl --user status swayidle.service
systemctl status netbird-wt0.service
ip link show wt0
ssh -G github.com | rg -i '^identityagent '
set -gx SSH_AUTH_SOCK "$HOME/.1password/agent.sock"
ssh-add -l
```

If needed, evaluate Niri, 1Password GUI, and NetBird declarations without assuming that evaluation proves runtime state:

```fish
nix eval --no-write-lock-file --json '.#nixosConfigurations.thoth.config.programs.niri.enable'
nix eval --no-write-lock-file --json '.#nixosConfigurations.thoth.config.programs._1password-gui.enable'
nix eval --no-write-lock-file --raw '.#nixosConfigurations.thoth.config.services.netbird.clients.wt0.interface'
```

## Sleep, locking, and hibernation

The [laptop policy](../features/power/laptop-sleep.nix) requests suspend-then-hibernate on lid close on battery and AC; docked lid closure is ignored. Hibernation follows 60 minutes of suspension, including on AC. UPower's awake-state battery thresholds are low 20%, critical 12%, and Hibernate at 8%. `swayidle.service` runs `swaylock -f` before sleep, tied to `niri.service`. Always verify the locker service before relying on lid-close suspension in public.

Before any approved deployment of power-policy changes:

```fish
nix eval --no-write-lock-file --raw '.#nixosConfigurations.thoth.config.services.logind.settings.Login.HandleLidSwitch'
nix eval --no-write-lock-file --raw '.#nixosConfigurations.thoth.config.systemd.sleep.settings.Sleep.HibernateDelaySec'
nix eval --no-write-lock-file --json '.#nixosConfigurations.thoth.config.services.upower.enable'
nix eval --no-write-lock-file --raw '.#nixosConfigurations.thoth.config.services.upower.criticalPowerAction'
nix eval --no-write-lock-file --raw '.#nixosConfigurations.thoth.config.boot.resumeDevice'
```

Review the branch diff and CI first. After applying logind policy changes, arrange an explicitly approved reboot: NixOS avoids restarting logind mid-session, so a switch may leave the old policy active. Then verify:

```fish
systemd-analyze cat-config systemd/logind.conf
systemd-analyze cat-config systemd/sleep.conf
systemctl --user status swayidle.service
systemctl status upower.service
upower -e
swapon --show
```

Use `upower -i <battery-object-path>` with an object path from `upower -e`; do not deliberately drain to 8% to test protection.

Before a controlled, approved manual hibernation test, save work, use reliable AC power, inspect `lsblk -f`, `sudo lvs`, `swapon --show`, `/sys/power/state`, and `/sys/power/disk`, and confirm the kernel advertises `disk`. With explicit permission, use `sudo systemctl hibernate`, then power on and confirm the previous session resumes. Repeat after the planned memory upgrade. Firmware/drivers can prevent resume despite valid Nix settings.

**Fresh-install precaution:** The host already imports `laptop-sleep`, so lid-triggered and critical-battery hibernation are active from first boot; this guide does not disable them. Keep the lid open and the laptop on reliable AC during initial bring-up, save work, and do not leave it unattended or rely on automatic transitions until multiple manual resume tests and the timed-transition/locking tests below pass. These precautions reduce exposure but do not disable the configured triggers. If automatic hibernation must be prevented during testing, request a separately reviewed and explicitly approved temporary power-policy configuration/deployment, then restore and verify the intended policy after testing. Do not silently change the configuration or assume untested resume is safe.

Separately test short lid-close suspension on AC: reopening should restore a **locked** Niri session. Then test the full 60-minute transition, RTC wake, LUKS unlock, and session restoration. Historical manual hibernation success is not proof of this timed transition. Useful diagnostics:

```fish
journalctl -b -u systemd-suspend-then-hibernate.service --no-pager
journalctl -b -k --no-pager | rg -i 'hibernat|resume'
```

## Updating the hardware report

`hardware/thoth/facter.json` and `flake.lock` are already tracked. Regenerate the hardware report only on Thoth, after meaningful hardware changes and explicit authorization; never substitute another host's report.

```fish
cd /Cosmos
nix run nixpkgs#nixos-facter -- -o hardware/thoth/facter.json
git diff -- hardware/thoth/facter.json
```

This report-generation command uses the `nixpkgs` registry entry; it is not guaranteed to use Cosmos' pinned nixpkgs. Review tool provenance for a report-update task. Use necessary permissions and restore ownership if required. Inspect identifiers and the complete diff before requesting approval to stage/commit. The repository is public: never publish credentials, private keys, recovery secrets, or LUKS key material.
