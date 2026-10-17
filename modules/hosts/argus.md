# Argus: dedicated Frigate NVR

Argus is named after the many-eyed guardian in Greek mythology. This guide covers
[argus.nix](argus.nix); repository rules are in [AGENTS.md](../../AGENTS.md).
Commands below are procedures, not evidence of installation or runtime testing.
Agents need separate permission to format, install, deploy, enroll NetBird, or reboot.

## Hardware and baseline

- Dell OptiPlex 3060 **Mini Tower**, not the Small Form Factor model.
- Intel Core i5-8500 (6 cores), approximately 15 GiB RAM visible to Linux.
- 128 GB SATA SSD for NixOS; 4 TB HDD dedicated to Frigate media.
- NVIDIA RTX A2000, 6 GB VRAM.
- Headless `x86_64-linux`, wired DHCP, user `twins` with Fish and sudo.
- No desktop, Home Manager, 1Password, container runtime, or Hermes installation.

The [Disko layout](../../disk-layouts/argus.nix) creates unencrypted GPT disks:
1 GiB FAT32 ESP, 4 GiB swap, and remaining SSD space as Bcachefs root with zstd
compression; the entire HDD is a separate XFS filesystem mounted at
`/var/lib/frigate`. Recordings, clips,
exports, and other Frigate state use the HDD. SQLite lives separately on the SSD
at `/var/lib/frigate-db/frigate.db`. Neither disk is redundant or backed up by
this configuration. Root uses the shared `bcachefs-root` profile and systemd
initrd, without LUKS, LVM, filesystem encryption, or automatic snapshot rollback.
The SSD and HDD remain independent filesystems, not a tiered Bcachefs pool.
XFS uses the pinned formatter's defaults; no custom allocation or video tuning
is applied. It cannot be shrunk and does not checksum recording contents.
Swap is not sized or configured for hibernation; sleep targets are disabled for
this always-on recorder.

The HDD has `nofail` so a missing media disk does not prevent management access.
Frigate requires that mount and checks it is a mount point before starting; it
must not fall back to writing media into the root SSD. Investigate a failed mount
rather than removing these guards. SMART monitoring and SSD trimming are enabled.

[Frigate](../features/video/frigate.nix) uses the native pinned NixOS service,
not Docker. The initial configuration intentionally has **no cameras**, with
recording, detection, and MQTT disabled. It is an installation baseline, not a
working recorder. NVIDIA's open kernel driver and `preset-nvidia` video decoding
are configured by the [headless NVIDIA profile](../features/video/nvidia-headless.nix).
This does **not** configure CUDA/TensorRT/ONNX object detection: model selection,
detector dependencies, and GPU inference are deferred until camera setup.
The driver selection under `services.xserver.videoDrivers` does not enable X11.

## Before installation

Use a NixOS installer booted in **UEFI** mode, with wired Ethernet and firmware
SATA mode set to **AHCI**, not Intel RST/RAID. Disable Secure Boot unless you have
separately arranged signed boot artifacts; this configuration does not provide
Secure Boot enrollment/signing. Use a checkout containing the reviewed Argus
changes on Thoth for remote installation, or on the Dell for the manual route.
An unpushed local branch on Thoth is not available to clone from GitHub. Examples
are **Bash**; hardware inspection and manual installation run on the Dell, while
the remote-install commands below run on Thoth.

The real [Dell Facter report](../../hardware/argus/facter.json) was generated on
this machine using `nixos-facter` 0.4.4 from Cosmos's pinned nixpkgs, then copied
back with matching SHA-256 hashes. The host consumes it through
`hardware.facter.reportPath`; Disko remains authoritative for filesystem layout.
The report includes the attached USB installer, but that is not a Disko target.
Review hardware identifiers before publishing; never substitute Thoth's report.
The inspected installer has working `r8169` Ethernet, SATA AHCI, UEFI boot, and
Secure Boot disabled. Recheck the actual environment before destructive work.
Verify the live kernel can load Bcachefs and mount a filesystem created with
Cosmos's pinned Bcachefs tools before formatting physical disks. A module file
reported by `modinfo bcachefs` alone does not prove it loads or that the on-disk
format is compatible. Do not reuse another host's kernel modules.

```bash
lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN
ls -l /dev/disk/by-id/
test -d /sys/firmware/efi && printf 'UEFI mode: yes\n'
lspci -nn
```

The layout declares these user-supplied whole-disk paths:

- SSD: `/dev/disk/by-id/ata-GIGASTONE_SSD_128GB_GSTPDEGAAB25250706`
- HDD: `/dev/disk/by-id/ata-ST4000VN008-2DR166_ZDHBZ39G`

Do not use a `-partN` symlink or guess `/dev/sda`/`/dev/sdb`; USB enumeration can
change them. Verify both declared paths on the Dell with `readlink -f` and
`lsblk`, including model, capacity, and serial. The SSD and HDD must be distinct,
and neither may be the installer. Back up anything to preserve. Declaring these
paths does not verify the physical disks or authorize erasing them.

For an SSH-based installation, the personal Cosmos admin **public** SSH key is
declared for `twins`; its private
key stays in 1Password on the administrator's clients, not on Argus. The same
public key may be authorized on other managed hosts without distributing the
private key to those servers. No initial password is provisioned, and sudo still
requires a password. Arrange to set it before the final reboot (for example,
from the live installer using `nixos-enter`), or use a local console afterward;
SSH key login alone does not provide passwordless sudo. The manual console-based
procedure below sets the user password before reboot. `nixos-anywhere`
can format both disks and reboot by default; remote installation requires
separate explicit approval and verified target identity.

## Evaluate and review the destructive plan

Use a `path:` flake reference so newly created/untracked host files are included
without staging them. Do not generate or import a replacement hardware config:
Disko already declares the filesystems, and the host supplies its boot baseline.

```bash
flake="path:$PWD"
nix eval --no-write-lock-file --raw "$flake#nixosConfigurations.argus.config.networking.hostName"
nix eval --no-write-lock-file --json --apply 'disks: builtins.mapAttrs (_: disk: disk.device) disks' \
  "$flake#nixosConfigurations.argus.config.disko.devices.disk"
nix eval --no-write-lock-file --raw "$flake#nixosConfigurations.argus.config.system.build.toplevel.drvPath"
nix run --no-write-lock-file "$flake#disko" -- \
  --mode destroy,format,mount --flake "$flake#argus" --dry-run
```

The pinned Disko dry run prints a generated script path. Read that script and
confirm **both** targets and all mounts. Dry-run/evaluation success does not prove
the selected devices are correct, that packages build, or that the Dell boots.

## Remote fresh install with pinned nixos-anywhere

Run from Thoth with the reviewed checkout at `/Cosmos`. The verified live-installer
SSH endpoint is `root@192.168.1.216`; it uses DHCP, so confirm the address and disk
identity again before proceeding. Authenticate through SSH's normal prompts or
an explicitly authorized agent key. Never put the temporary root password in
commands, the repository, or an environment file.

The flake exposes `.#nixos-anywhere` from its already-pinned nixpkgs (currently
1.13.0), without another flake input or a lock update. Check the CLI and build the
system locally before approving destructive work:

```bash
cd /Cosmos
nix run --no-write-lock-file path:/Cosmos#nixos-anywhere -- --help
nix build --no-write-lock-file --no-link path:/Cosmos#nixosConfigurations.argus.config.system.build.toplevel
```

**Destructive: only after explicit approval to erase both verified SATA disks
and install Argus.** The Dell is already in a NixOS live installer, so omit
`kexec`. Explicitly omit the `reboot` phase to leave time for password setup and
mount/boot-entry verification:

```bash
nix run --no-write-lock-file path:/Cosmos#nixos-anywhere -- \
  --flake path:/Cosmos#argus \
  --target-host root@192.168.1.216 \
  --build-on local \
  --phases disko,install
```

This is **not a dry run**. It formats both declared disks and installs NixOS;
it intentionally does not reboot. Do not add `--generate-hardware-config`: the
real reviewed report is already present. The local flake is sufficient; pushing
the branch is not an installation prerequisite. The installer may add its own
temporary SSH key to the live environment; this is distinct from the persistent
Cosmos admin public key declared for `twins`.

After successful installation, inspect the target while still in the live
installer. Set a new `twins` password interactively for sudo/console access; do
not reuse or disclose the temporary installer password. Copy the reviewed
checkout so it survives the installer reboot:

```bash
ssh root@192.168.1.216 'findmnt /mnt; findmnt /mnt/boot; findmnt /mnt/var/lib/frigate; ls /mnt/boot/loader/entries'
ssh -t root@192.168.1.216 "nixos-enter --root /mnt -c 'passwd twins'"
scp -r /Cosmos root@192.168.1.216:/mnt/
```

Stop if installation, mounts, password setup, or boot entries fail. Arrange a
separately approved reboot rather than running the destructive installation
again. After reboot, reconnect as `twins` at the actual DHCP address using the
1Password-backed key. Verify the new SSH host fingerprint through the console
before replacing a stale known-hosts entry; do not disable host-key checking.
Use `sudo chown -R twins:users /Cosmos` to restore checkout ownership. Verify
SSH, sudo, HDD mounting, NetBird enrollment, Frigate auth, and the NVIDIA driver
on the installed system; the camera-free baseline still does not record video.

### Recovering a failed format or interrupted install

Do not blindly repeat `disko,install`: that can erase successfully prepared
filesystems again. Inspect the actual mount tree, filesystem signatures, and
kernel logs first. Repartitioning can expose old filesystem signatures at the
same offsets. In particular, a stale ZFS label on the media partition can make
Disko skip creation of the declared filesystem because its generic filesystem
step detects an existing `TYPE`, then fail when mounting it as the configured type.

Only within explicitly approved erase scope, verify the media partition's parent
by-id disk and serial, confirm it is unmounted, clear signatures on that specific
partition, and create the declared filesystem with the pinned formatter. Verify
the resulting type and mount before continuing. Once all reviewed mounts are
correct, resume with `--phases install`, omitting `disko`, `kexec`, and `reboot`.
If the desired layout changed during an interruption, rebuild and review the new
plan first; existing ext4 filesystems are not converted to Bcachefs root or XFS
media merely by resuming the install phase. Obtain approval before applying a
replacement layout.

## Alternative: manual installation from the Dell console

Run this alternative from a checkout on the Dell, **not** from Thoth and not in
addition to an already completed remote installation. Set `flake="path:$PWD"`
in that checkout first.

Only after separate approval for the destructive installation and verification
of both real devices, run the following on **Argus**, never Thoth. This erases
**all data on both selected disks**:

```bash
nix run --no-write-lock-file "$flake#disko" -- \
  --mode destroy,format,mount --flake "$flake#argus"
findmnt /mnt
findmnt /mnt/boot
findmnt /mnt/var/lib/frigate
lsblk -f
swapon --show
```

Stop unless Bcachefs SSD root, FAT32 SSD ESP, SSD swap, and XFS HDD media mounts
match the reviewed plan. Then, with separate installation permission:

```bash
sudo nixos-install --root /mnt --flake "$flake#argus" --no-root-passwd --max-jobs 1 --cores 2
sudo nixos-enter --root /mnt -c 'passwd twins'
sudo cp -a "$PWD" /mnt/Cosmos
ls /mnt/boot/loader/entries
ls /mnt/boot/EFI/systemd
```

Set the `twins` password locally before reboot for sudo and console login. The
public SSH key is declared in the configuration, but no initial password or
private key is included, and root SSH login is not the bootstrap mechanism.
Keep a local console available. Reboot only after successful installation, verified boot entries, and
separate reboot approval. After first boot, restore checkout ownership if needed:
`sudo chown -R twins:users /Cosmos`.

## First boot and NetBird

The shared `base` profile starts OpenSSH and NetBird client `wt0`; startup is not
enrollment or proof of peer connectivity. SSH retains `openFirewall = true`, so
it is reachable on the LAN, **not NetBird-only**. No SSH identity agent is forced
on this host. Establish overlay access before considering tighter SSH exposure.

The native Frigate module configures nginx with authentication. TCP 80 is allowed
on `wt0`, not opened globally to the LAN. No router port-forward, public HTTPS,
RTSP restream, or WebRTC firewall exposure is configured. The shared NetBird
profile also enables its internal-firewall policy; use NetBird access policies
to restrict which peers can reach this NVR. Do not treat port 80 as the only
service reachable by authorized overlay peers.

Read-only checks, on Argus after installation:

```bash
findmnt /var/lib/frigate
systemctl status netbird-wt0.service frigate.service nginx.service --no-pager
sudo netbird-wt0 status
ip link show wt0
nvidia-smi
sudo journalctl -b -u frigate.service --no-pager
```

With separate enrollment approval, `sudo netbird-wt0 up` starts interactive login;
follow its authentication link on another device. Never commit setup keys or paste
credentials into chat. Verify `sudo netbird-wt0 status`, then test SSH and the web
UI from an authorized peer using Argus's NetBird address. An overlay IP does not
require DNS for the nginx default vhost in this single-vhost baseline.

Before enrollment, from a trusted workstation use an SSH tunnel for the UI:

```bash
ssh -N -L 8080:127.0.0.1:80 twins@ARGUS_LAN_IP
```

Open `http://127.0.0.1:8080`, or after enrollment `http://ARGUS_NETBIRD_IP` over
the encrypted overlay. Obtain Frigate's generated initial admin password locally
from the service journal and change it in the UI; do not paste the journal's
credential-bearing lines into chat or Git. No LAN plaintext web login is exposed.
The configuration editor's runtime copy is not the declarative source of truth.

## Camera bring-up later

Edit `services.frigate.settings` in the feature module (or extend it in the host)
when camera details are available. Keep credentials out of Git and the Nix store;
use runtime `FRIGATE_...` environment substitutions backed by a local protected
file, configured in the service, when adding streams.

Before enabling recording/detection:

- Identify camera models, main/substream URLs, codecs, resolutions, and frame rates.
- Use main streams for recording and lower-resolution substreams for detection
  where available; configure actual per-camera input roles.
- Set recording and retention policy appropriate to aggregate bitrate and the
  4 TB disk. Capacity alone does not establish a retention duration.
- Verify `preset-nvidia` against actual codecs and GPU/FFmpeg logs. Hardware video
  decoding and AI object detection are different workloads.
- Choose and validate a detector/model separately. Do not assume the native
  package provides NVIDIA inference just because the driver loads.
- Enable MQTT only if an actual broker/integration is wanted.
- Re-evaluate all hosts and build before an approved deployment. Verify UI auth,
  real recording files on the HDD, database writes on the SSD, retention cleanup,
  GPU use, network access, and restart behavior on the physical Dell.

Routine approved updates use `sudo nixos-rebuild switch --flake path:/Cosmos#argus`.
**Never run Disko formatting for routine updates.** No installation, full-system
build, boot, enrollment, camera recording, or GPU-runtime success is implied by
this guide or Nix evaluation.
