# Odin: headless model-server foundation

This guide covers [odin.nix](odin.nix). Follow [AGENTS.md](../../AGENTS.md)
for repository rules and separate approval for hardware reports, formatting,
installation, enrollment, and reboot. Commands are Bash procedures, not evidence
that installation or runtime verification has succeeded.

## Hardware and scope

- AMD Ryzen 9 5900X, ASRock B550 Taichi, 128 GB RAM (about 125 GiB usable).
- AMD Navi 31 GPU (reported as RX 7900 XT by the owner) and Intel Arc Pro B50.
- One 1 TB addlink PCIe NVMe, serial `A4D01953036200206341`.
- Headless `x86_64-linux`, wired DHCP, hostname `odin`, admin `twins` with Fish.
- Shared `base`: OpenSSH, resolved, firewall, NetBird client/interface `wt0`.
- No desktop, Home Manager activation, 1Password, or container runtime.
- The `model-tools` profile supplies the native Hugging Face `hf` CLI. It does
  not download a model or enable an HTTP inference service.
- SYCL/oneAPI is the selected llama.cpp backend for the Intel B50. Toolchain
  validation and model serving are separate steps; speech/image services and
  ROCm remain deferred.
- Bluetooth is explicitly disabled, overriding Facter's hardware-based default;
  the BlueZ userspace stack and Bluetooth service are not enabled or installed.
- SSD trimming and SMART monitoring enabled; sleep/hibernation targets disabled.

The real [Facter report](../../hardware/odin/facter.json) was generated on Odin
with `nixos-facter` 0.4.4 from Cosmos's pinned nixpkgs. Its remote/local SHA-256
hashes matched. It includes attached installer hardware; never substitute another
host's report. Review its machine identifiers before publishing.

## Storage

The [Disko layout](../../disk-layouts/odin.nix) targets only:

```text
/dev/disk/by-id/nvme-addlink_M.2_PCIE_G5x4_NVMe_A4D01953036200206341
```

Three ordinary GPT partitions, with no LVM or encryption:

1. 1 GiB FAT32 ESP mounted at `/boot` with restrictive permissions.
2. 4 GiB Linux swap, a memory-pressure fallback, not hibernation storage.
3. Remaining capacity: Bcachefs root at `/`, label `odin-root`, zstd compression
   and `noatime`.

The shared `bcachefs-root` profile enables Bcachefs support and systemd initrd,
and disables zram. Merely including LVM support in a default initrd is not using
LVM for this layout. This single disk has no redundancy, automatic snapshot
rollback, or backup policy. Model storage initially shares root.

## Preflight and validation

Boot a NixOS ISO in UEFI mode with Secure Boot disabled and wired Ethernet.
The inspected installer address was `192.168.1.142`; DHCP may change it. Its Intel
I225-V Ethernet used `igc`, and the live GPUs used `amdgpu` and `xe`. Those
observations do not verify the installed kernel or an inference backend.

On Odin, recheck identity, serial, mounts, and installer separation before any
destructive action:

```bash
hostname
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL,TRAN
readlink -f /dev/disk/by-id/nvme-addlink_M.2_PCIE_G5x4_NVMe_A4D01953036200206341
wipefs --no-act /dev/disk/by-id/nvme-addlink_M.2_PCIE_G5x4_NVMe_A4D01953036200206341
test -d /sys/firmware/efi
bootctl status --no-pager
```

The inspected 256 GB Kioxia USB disk is the Ventoy installer, not an installation
target. No listed partitions/signatures on the NVMe is not authorization to erase
it. Verify the SSH host fingerprint through the local console when it changes;
never disable host-key checking. Use the Cosmos Admin key in the client agent,
not credentials in commands or Git.

From the reviewed checkout on Thoth, use `path:` references to include untracked
new files without staging. Follow all-host evaluation and lint order in
[AGENTS.md](../../AGENTS.md), then build Odin and review Disko's generated script:

```bash
cd /Cosmos
nix build --no-write-lock-file --no-link path:/Cosmos#nixosConfigurations.odin.config.system.build.toplevel
nix run --no-write-lock-file path:/Cosmos#disko -- \
  --mode destroy,format,mount --flake path:/Cosmos#odin --dry-run
```

Read the generated script: exactly one physical disk and three partitions must
match the approved plan. Before formatting, verify the live installer can load
its own Bcachefs module and mount/read/write a disposable file-backed filesystem
created with Cosmos's pinned formatter. `modinfo` alone does not test this.
Never load another host's kernel modules or use the physical NVMe for a probe.

## Approved remote installation only

Obtain explicit approval for erasing the identified NVMe and installing Odin.
Building, reviewing the layout, or approving a commit does not authorize this.

Prefer direct strict SSH for this host. The pinned `nixos-anywhere` helper
prepends `StrictHostKeyChecking=no` and `UserKnownHostsFile=/dev/null`; appended
`--ssh-option` settings do not override them because OpenSSH uses the first
value. Do not assume passing stricter duplicate options fixes that behavior.
The direct route below transfers the same reviewed pinned artifacts, without
using the helper's SSH policy or invoking kexec/reboot.

From Thoth, with the verified installer host-key file and Cosmos Admin agent:

```bash
cd /Cosmos
set -euo pipefail
export SSH_AUTH_SOCK=/home/twins/.1password/agent.sock
known_hosts="$TMPDIR/odin-installer-hostkey-current"
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts")
export NIX_SSHOPTS="-o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known_hosts"
system=$(nix build --no-write-lock-file --no-link --print-out-paths \
  path:/Cosmos#nixosConfigurations.odin.config.system.build.toplevel)
dry_run=$(nix run --no-write-lock-file path:/Cosmos#disko -- \
  --mode destroy,format,mount --flake path:/Cosmos#odin --dry-run)
printf '%s\n' "$dry_run"
disko_script="${dry_run##*$'\n'}"
case "$disko_script" in
  /nix/store/*/bin/disko-destroy-format-mount) ;;
  *) printf 'Unexpected Disko script path\n' >&2; exit 1 ;;
esac
nix copy --to ssh://root@192.168.1.142 "$system" "${disko_script%/bin/*}"
```

Read the generated Disko script and reverify the target identity/serial on Odin.
Only with the separate destructive approval, this command erases the declared
NVMe and creates/mounts its filesystems:

```bash
ssh "${ssh_options[@]}" root@192.168.1.142 \
  "set -eu; install -d -m 700 /root/cosmos-install-work; export TMPDIR=/root/cosmos-install-work; '$disko_script' --yes-wipe-all-disks"
```

Before installing, verify Bcachefs at `/mnt`, FAT32 at `/mnt/boot`, and a real
swap signature on partition 2. Disko's generic existing-filesystem checks can
skip formatting when old signatures survive a new partition table. In
particular, inspect both ESP and swap: an old Fedora ESP may be reused and an
old ext4 signature may prevent `mkswap`. Within the approved erase scope only,
unmount the verified ESP, confirm neither ESP nor swap is in use, clear their
signatures with the pinned `wipefs`, recreate FAT32/swap with the pinned tools,
and remount the ESP. Preserve the correctly formatted Bcachefs root. Do not
rerun whole-disk formatting to repair these two partitions.

After mount/type verification, install the exact transferred build:

```bash
ssh "${ssh_options[@]}" root@192.168.1.142 \
  "export TMPDIR=/root/cosmos-install-work; nixos-install --root /mnt --system '$system' --no-root-passwd --no-channel-copy --max-jobs 1 --cores 2"
```

This does not reboot. Do not regenerate hardware configuration: the real Facter
report and Disko are declared. If interrupted, inspect mounts and signatures,
then repeat only the closure transfer/install step once the correct filesystems
are mounted. Do not blindly repeat Disko and erase them again.

After successful installation, inspect `/mnt`, `/mnt/boot`, swap, and boot entries.
Set the admin password interactively on the console or a trusted interactive SSH
terminal; never send it to chat. No password is stored in Git, sudo requires a
password, and SSH key access alone does not bootstrap sudo:

```bash
ssh root@192.168.1.142 'findmnt /mnt; findmnt /mnt/boot; swapon --show; ls /mnt/boot/loader/entries'
ssh -t root@192.168.1.142 "nixos-enter --root /mnt -c 'passwd twins'"
scp -r /Cosmos root@192.168.1.142:/mnt/
```

Obtain separate reboot approval. After first boot, verify the installed SSH
fingerprint locally, reconnect as `twins` at the actual DHCP address, test sudo,
and restore checkout ownership with `sudo chown -R twins:users /Cosmos`.

## Installed-system checks and later work

On Odin after reboot:

```bash
hostname
findmnt /
findmnt /boot
swapon --show
systemctl --failed --no-pager
systemctl status sshd.service netbird-wt0.service smartd.service --no-pager
ip -br address
sudo netbird-wt0 status
readlink -f /sys/bus/pci/devices/0000:0d:00.0/driver
readlink -f /sys/bus/pci/devices/0000:10:00.0/driver
sudo -v
```

The minimal installed base does not include `lspci`; the sysfs checks above
verify the observed AMD/Intel driver bindings without adding diagnostic packages.
Run multi-command remote Bash checks with `ssh ... 'bash -s'` and a script on
standard input: `twins` uses Fish, so unwrapped Bash conditionals are not valid
remote shell commands.

SSH opens its port broadly through the shared profile; it is not NetBird-only.
NetBird startup is not enrollment or peer connectivity. With separate enrollment
approval, use `sudo netbird-wt0 up` interactively and test access from an authorized
peer before considering tighter SSH rules. Never commit setup keys.

## Hugging Face and Intel GGUF tooling

The [model-tools profile](../features/inference/model-tools.nix) uses
`pkgs.python3Packages.huggingface-hub` for the `hf` command. No pip/uv installation,
overlay, or new flake input is needed for that CLI. The configuration adds
`twins` to `render` for render-node access; start a fresh login after an approved
activation to pick up changed supplementary groups.

After activating the reviewed configuration, these commands work in Fish or Bash:

```bash
hf version
hf download --help
```

The pinned CLI was exercised directly from its Nix store path on Odin and
reported version 1.30.0. It is not installed into the active system profile until
an approved activation. The backend choice is Intel SYCL/oneAPI, not Vulkan.
The temporary Vulkan device probe confirmed the B50's identity but did not
establish SYCL support or model inference; it is not part of the selected profile.

A disposable SYCL build/kernel probe runs separately from the system
configuration before the llama.cpp service is enabled. Intel license allowance
must remain package-specific; do not enable unfree packages globally or install
an untracked toolkit into `/opt`. Keep the AMD driver configuration independent.

Keep weights and Hugging Face caches outside the Nix store. Download a selected
GGUF file, not an entire repository containing every quantization. Pin its Hub
revision for reproducibility. Public ungated models do not require an account;
if authentication is needed, log in interactively as the operator and never
commit a token or embed one in a system service/Nix expression. Do not use
`hf update` to replace a Nix-managed installation.

No HTTP service is enabled by the model-tools profile. Choose the exact Gemma 4
GGUF, model directory, context/concurrency limits, and network exposure before
enabling serving. Model download, activation, GPU offload, API health, and real
generation must each be verified separately. Your brother's account and other
inference backends remain follow-up work.

Routine approved updates use `sudo nixos-rebuild switch --flake path:/Cosmos#odin`.
Never run Disko formatting for routine updates.
