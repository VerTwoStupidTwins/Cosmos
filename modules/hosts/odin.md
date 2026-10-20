# Odin: headless model-server foundation

This guide covers [odin.nix](odin.nix) and the on-demand model roster in
[odin-inference.nix](odin-inference.nix). Follow [AGENTS.md](../../AGENTS.md)
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
- The `llama-cpp-sycl` profile provides Intel compute prerequisites. The reusable
  `llama-cpp-instances` profile declares independent Intel SYCL and AMD Vulkan
  instances; both are disabled and have no model selected.
  Speech/image services and ROCm remain deferred.
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
The shared NetBird profile sets `config.ServerSSHAllowed = false`: NetBird is
the VPN transport, while OpenSSH handles SSH keys and local-user authentication.
Do not enable the embedded NetBird SSH server or use `--disable-ssh-auth` as a
password-login fix; its JWT authentication is separate from Linux passwords.
NetBird startup is not enrollment or peer connectivity. With separate enrollment
approval, use `sudo netbird-wt0 up` interactively and test access from an authorized
peer before considering tighter SSH rules. Never commit setup keys.

### Migrating from embedded NetBird SSH

Keep a verified LAN/console session open while applying this change. Follow the
normal review, validation, and separate activation approval requirements; no
disk, password, or enrollment changes are needed. The NixOS NetBird pre-start
script merges the declared setting when `netbird-wt0.service` starts. After
activation, check the generated setting and, with approval for the brief VPN
interruption, restart the service if the running client still serves embedded
SSH. Run these commands on Odin through LAN/console, not through the VPN session
being restarted:

```bash
jq -e '.ServerSSHAllowed == false' /etc/netbird-wt0/config.d/50-nixos.json
sudo systemctl restart netbird-wt0.service
systemctl is-active netbird-wt0.service sshd.service
sudo netbird-wt0 status
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Disable Odin's embedded SSH Access toggle in the NetBird dashboard as well, and
retain a normal **TCP port 22** access policy from the authorized client/group
to Odin. A `NetBird SSH` policy is for the embedded server, not OpenSSH.

The NetBird SSH host key and OpenSSH host key are different. A client that
previously trusted the embedded server will report a changed host key. Verify
the OpenSSH fingerprint through the trusted LAN/console connection first, then
replace only the affected NetBird IP/hostname entries in `known_hosts`. Never
disable host-key checking or remove unrelated entries. From Thoth, test both
`ssh twins@<odin-netbird-ip>` and the actual remote-network connection, confirming
the SSH server is OpenSSH and login works with the Cosmos Admin key.

## Hugging Face and independent GPU instances

The [model-tools profile](../features/inference/model-tools.nix) uses
`pkgs.python3Packages.huggingface-hub` for the `hf` command. No pip/uv installation,
overlay, or new flake input is needed for that CLI. The configuration adds
`twins` to `render` for render-node access; start a fresh login after an approved
activation to pick up changed supplementary groups.

After activating the reviewed configuration, these commands work in Fish or Bash:

```bash
hf version
hf download --help
llama-server-intel --version
llama-server-intel --list-devices
llama-server-amd --version
llama-server-amd --list-devices
```

The pinned CLI was exercised directly from its Nix store path on Odin and
reported version 1.30.0. It is not installed into the active system profile until
an approved activation.

The [instance module](../features/inference/llama-cpp-instances.nix) exposes
`services.llama-cpp-instances.<name>`. Each entry has `enable`, `package`, `host`,
`port`, `model`, `settings`, `environment`, `renderDevice`, `allowJit`, and
`openFirewall` options. The module creates `llama-cpp-<name>.service` only for
enabled entries. A named `llama-server-<name>` launcher remains available for
diagnostics even when the service is disabled; it applies that entry's backend,
environment, and CLI settings. Backend packages are referenced by their full
Nix store paths instead of installing colliding `llama-server` binaries in PATH.

Odin declares:

| Instance | Backend/GPU | Local endpoint | Explicit device |
| --- | --- | --- | --- |
| `intel` | Intel oneAPI/SYCL, Arc Pro B50 | `127.0.0.1:8080` | `SYCL0` |
| `amd` | Vulkan, Radeon 7900 XT | `127.0.0.1:8081` | `Vulkan0` |

Both standalone entries have `enable = false`, `model = null`, and
`openFirewall = false`. They supply backend packages and diagnostic launchers;
Odin instead enables the [native llama-swap profile](../features/inference/llama-swap.nix)
to own the on-demand AMD children. Do not also enable the standalone AMD server:
it would compete with llama-swap for VRAM. These declarations are not proof of
activation. The upstream singleton `services.llama-cpp` remains disabled.
Enabled standalone instances must have distinct ports
and an absolute model filename; reserve `host`, `port`, and `model` for their
dedicated options instead of aliases under `settings`.

Each service has its own dynamic user, `/var/lib/llama-cpp-<name>` state and
`/var/cache/llama-cpp-<name>` cache, supplementary `render` access, and a closed
device policy allowing only its stable PCI render node. Models under `/home`
are hidden by service hardening: provision readable weights outside home, such
as `/var/lib/llama-models`, without making them writable by the services.
`allowJit` relaxes executable-memory hardening only for the Intel entry, where
oneDNN may require it. Ports open only when an entry is both enabled and
explicitly has `openFirewall = true`; defaults remain loopback-only.

The Intel entry selects the [native SYCL package](../../packages/llama-cpp-sycl/default.nix),
extending pinned nixpkgs llama.cpp with the pinned compiler, oneMKL, oneDNN, and
Level Zero. Its [prerequisite profile](../features/inference/llama-cpp-sycl.nix)
permits only `intel-oneapi-toolkit` as unfree; do not enable unfree packages
globally or install an untracked toolkit into `/opt`.

The package wrappers select `level_zero:gpu` and expose Intel's compute runtime,
Level Zero loader, and graphics compiler libraries only to those commands. The
graphics compiler libraries are needed for runtime kernel compilation. No global
library path or GPU selector is set. The AMD entry uses `pkgs.llama-cpp-vulkan`
with only Mesa's Radeon ICD exposed through its own `VK_DRIVER_FILES` value.
Its driver file is taken from the pinned Mesa package, not guessed from a
global environment. Explicit device selection prevents a silently CPU-only
service when the requested GPU is absent; CPU helper kernels remain available.

Odin enables the package's `forceThreadGroupPreemption` argument. With the pinned
kernel/runtime, its B50 HWCONFIG response omits CSR-size tag 62; the runtime then
aborts on a zero-sized mid-thread preemption buffer. The wrappers set
`NEOReadDebugKeys=1` and `ForcePreemptionMode=3` (thread-group preemption) for this
package only. The independent SYCL kernel probe passed with those settings and
the graphics compiler library path. This is a scoped compatibility workaround,
not proof that the default runtime path or model inference works. Re-test it
when updating the kernel or Intel runtime before removing the override.

The package includes a small registration guard for GPU-less Nix sandboxes:
when no SYCL GPU exists, it declines registration instead of letting the upstream
default-device selector terminate the CPU test suite. The upstream CPU tests
remain enabled; actual GPU execution must be tested outside the build sandbox.

Keep weights and Hugging Face caches outside the Nix store. Download a selected
GGUF file, not an entire repository containing every quantization. Pin its Hub
revision for reproducibility. Public ungated models do not require an account;
if authentication is needed, log in interactively as the operator and never
commit a token or embed one in a system service/Nix expression. Do not use
`hf update` to replace a Nix-managed installation.

Choose the exact GGUF for each entry, model directory, context/concurrency
limits, and network exposure before enabling serving. Entries may use different
models or share one readable GGUF file, but GPU allocations and contexts remain
separate; this does not pool the cards' VRAM. Model download, activation, GPU
offload, API health, and real generation must each be verified separately.
Your brother's account remains follow-up work.

After models are provisioned and activation is separately approved, each server
can be enabled independently. Then verify the corresponding unit and endpoint:

```bash
systemctl status llama-cpp-intel.service llama-cpp-amd.service
curl --fail http://127.0.0.1:8080/health
curl --fail http://127.0.0.1:8081/health
```

The module's flake check exercises enabled/disabled instances, isolated state,
environment/device permissions, opt-in firewall/JIT, invalid configurations, and
literal CLI argument transport. Its test executable is an argument-printing
fixture, not simulated model inference.

## On-demand Radeon inference with llama-swap

[odin-inference.nix](odin-inference.nix) configures the pinned native
`services.llama-swap`, not Docker or a second always-running AMD server.
After activation the endpoint remains `http://127.0.0.1:8081/v1`, with the
built-in playground at `http://127.0.0.1:8081/ui/`. No firewall port opens.
Child servers bind loopback on automatically assigned ports starting at 18081;
the temporary experiment's NetBird listeners on 8090/8091 are not promoted into
this configuration.

| API model ID | Context | Slots | Weights / expert offload / decoding |
| --- | --- | --- | --- |
| `barozp-reap-q6` | 131072 total tokens | 1 | Q6_K; first 11 MoE layers on CPU; native MTP up to 3 draft tokens |

The `rx-7900xt` group uses `swap = true`, so future models added to that group
replace one another rather than share the card. `exclusive = false` leaves
other groups untouched; `persistent = true` prevents other groups from evicting
this one. Neither setting preloads a model. Future B50 models still need their
own backend environment, render-device permission, and group; this change does
not enable Intel serving or pool VRAM.

The declared arguments preserve the tested single-slot configuration:

- `Vulkan0`, 99 GPU layers, 11 CPU MoE layers on both main and MTP paths, fit off.
- One 131072-token context, parallel 1, no unified KV cache.
- 12 generation/prefill threads; batch/microbatch 1024/256; flash attention on.
- `q8_0` K/V caches for both main and draft; MTP maximum 3, minimum 0, p-min 0.
- `--cache-prompt --cache-ram 32768 --cache-idle-slots` for host RAM snapshots.
- `--load-mode mmap+mlock --lazy-mode off --sleep-idle-seconds -1`.
- Jinja, DeepSeek reasoning format, temperature 0.6, top-p 0.95, top-k 20;
  metrics and slot endpoints enabled. Unsupported `--cache-reuse` stays absent.

The proxy service declares `LimitMEMLOCK=infinity`, inherited by its children;
no runtime user-manager `prlimit` adjustment is needed for this system service.
Mapped locking pins CPU-resident model allocations, not a duplicate of all GPU
weights in RAM. Standalone `--load-mode mlock` crashed the tested build and is
not selected. Verify actual locked memory after activation rather than assuming
that a flag establishes residency.

Model `ttl = 0` disables the proxy's inherited 600-second idle unload. Once
requested, the model and its RAM prompt cache remain until an explicit unload,
a same-group model swap, or process/service termination. Cache RAM is a 32768 MiB
budget, not an immediate allocation. The model's response-header timeout is
1800 seconds to accommodate long non-streaming prefills.

Context includes formatted input, reasoning and output. Cold retrieval passed
through 65554 input tokens, and prefix/conversation-switch caching was exercised.
Full near-capacity 128K operation and coding/planning executor quality remain
unvalidated. The shared proxy keeps request/response body capture disabled.

### Runtime artifact and activation

The selected publisher is
[`barozp/Qwen3.6-29B-REAP-Opus-Reasoning-Distill-MTP-GGUF`](https://huggingface.co/barozp/Qwen3.6-29B-REAP-Opus-Reasoning-Distill-MTP-GGUF),
pinned at Hub revision `f11f37b9ad21038478066fc1e532dfb92165fccf`.
The selected file is `Qwen3.6-29B-REAP-Opus-Reasoning-Distill-MTP-Q6_K.gguf`,
23795817760 bytes, with publisher SHA-256:

```text
27b6c065ff4ba02d76dc11116ecebb78b4bc38aaa27637414c8008ba000db4ae
```

The source file under
`/home/twins/.local/share/cosmos-models/barozp-qwen36-reap-opus-mtp/f11f37b9ad21038478066fc1e532dfb92165fccf/`
was rehashed against that pinned publisher metadata. It must exist for initial
provisioning; the service does not download weights.

The `odin-inference-models.service` oneshot runs before llama-swap and copies
only this selected artifact into
`/var/lib/llama-models/qwen36-reap-opus-mtp-f11f37b9ad21/`. It requests reflinks
where supported, checks copied bytes, and publishes atomically with mode `0444`.
Existing destination files are checked, not overwritten. The dynamic proxy
user cannot modify these root-owned files; `ProtectHome` remains enabled. Once
a valid destination copy exists, the source cache is not needed on later starts.
Model files stay outside the Nix store.

The retired LFM and checksum-mismatched APEX entries are no longer served or
required by provisioning. Their cached/provisioned files are not deleted, and
removing the APEX entry does not resolve its publisher-checksum mismatch.

Run Nix evaluations, validation, and builds on Odin, not on Thoth. Thoth may
edit/stage the changes and drive strict SSH; first transfer the exact pending
files onto a clean, matching feature branch in Odin's `/Cosmos` checkout and
verify their contents. Do not write directly onto Odin's `main` or discard
remote changes. Build completion is not activation permission.

Before first activation, obtain separate approval to stop the temporary backend
and test proxy: leaving the old backend resident would compete for Radeon VRAM.
Only after that approval, on Odin:

```bash
systemctl --user stop barozp-test-swap.service \
  barozp-reap-q6-q8-cpu11-ram32-single128k-test.service
sudo nixos-rebuild switch --flake path:/Cosmos#odin
systemctl status odin-inference-models.service llama-swap.service
systemctl show llama-swap.service -p LimitMEMLOCK
curl --fail http://127.0.0.1:8081/health
curl --fail http://127.0.0.1:8081/v1/models
```

An idle healthy proxy does not prove backend loading. Request `barozp-reap-q6`,
verify real generation and native tool calls, and inspect `/running`. Check the
child's single 131072-token slot, Vulkan device, effective arguments, locked
memory and swap usage. Check prompt-cache reuse and that an idle model is not
unloaded after 600 seconds. These are post-activation checks, not claims that
system-service inference has already passed. The flake check verifies arguments,
GPU-specific routing, model paths, service dependencies and unit syntax; it is
not GPU inference.

The proxy's `/api/models/unload` endpoint unloads models but leaves the proxy
available. Intel remains independent and disabled; SYCL environment/workarounds
are not applied to Vulkan children.

For remote use without exposing the unauthenticated UI/API, forward the loopback
endpoint from a client with an authorized SSH key:

```bash
ssh -N -L 8081:127.0.0.1:8081 twins@192.168.1.120
```

Then use `http://127.0.0.1:8081/v1` and `/ui/` on that client. Brother-specific
SSH authorization and direct LAN/NetBird serving remain separate work. Do not
bind `0.0.0.0` or open a firewall port as an implicit consequence of this change.

Routine approved updates use `sudo nixos-rebuild switch --flake path:/Cosmos#odin`.
Never run Disko formatting for routine updates.
