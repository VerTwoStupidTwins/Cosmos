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
- No desktop, Home Manager activation, or 1Password GUI. The Honcho prerequisites
  below add rootless Podman and native PostgreSQL, not a Docker daemon.
- The `model-tools` profile supplies the native Hugging Face `hf` CLI. It does
  not download a model or enable an HTTP inference service.
- The `llama-cpp-sycl` profile provides Intel compute prerequisites. The reusable
  `llama-cpp-instances` profile declares independent Intel SYCL and AMD Vulkan
  instances; both are disabled and have no model selected.
  Speech/image generation services and ROCm remain deferred; the proxy roster
  below adds multimodal embeddings on the B50.
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
to own AMD reasoning children and a resident B50 embedder. Do not also enable
either standalone server: it would compete for that GPU's VRAM. These declarations are not proof of
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
default-device selector terminate the CPU test suite. The default package keeps
upstream CPU tests enabled; actual GPU execution must be tested outside the build
sandbox. Odin selects the
[shared B50 override](../../packages/llama-cpp-sycl/b50.nix)
for Intel: it pins llama.cpp `4fbc76dec51d0add466f0210855c0596589b60d4`, enables
`GGML_SYCL_F16`, and builds the HTTP API without the bundled UI or upstream test
suite. EmbeddingGemma2 and Clef use this one package, not separate precision
variants or additional standalone servers. A single output avoids the newer CMake
exports' `out -> dev -> out` cycle. Only this override disables `fortify` and
`fortify3`: host fortification otherwise leaks the unresolved `__memcpy_chk`
symbol into SYCL device code. Other hardening and the Radeon build are unchanged.

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

## SOPS secret-management bootstrap

Odin imports the reusable `sops-secrets` profile. The pinned sops-nix input
follows Cosmos's root nixpkgs. It converts the existing root-only
`/etc/ssh/ssh_host_ed25519_key` during secret installation; no host private key
is exported and no additional age key is generated. GPG/RSA key imports are
disabled. This profile installs no Hermes
account or service yet; a successful build does not prove host decryption.

A non-secret activation probe is declared by
[`sops-bootstrap.nix`](sops-bootstrap.nix). After approved activation,
`/run/secrets/bootstrap-validation` must be owned by `root:root`, mode `0400`,
and contain `public-cosmos-sops-bootstrap`. It is deliberately not a
password or application credential. Actual host-key decryption and permissions
must be checked after activation, not inferred from operator decryption.

The single repository-wide encrypted file is [`secrets.yaml`](../../secrets.yaml).
The policy in [`.sops.yaml`](../../.sops.yaml) has one key group containing the
Cosmos SOPS Operator, Odin and Thoth: each identity can decrypt independently.
Consequently, root on either host can decrypt the entire shared file, not just
that host's entries. Service access is still limited to explicitly declared
runtime entries and their ownership/mode. Public recipients may be committed, but
private identities and plaintext credentials must never enter Git, the Nix store,
or chat. Ordinary editing uses the operator identity via 1Password; system
activation uses the root-only host key. These are workflow/permission roles,
not cryptographically distinct read and edit permissions.

Operator editing can happen on any authorized computer with access to the same
Cosmos SOPS Operator item in 1Password; the operator recipient is tied to that
key, not to Thoth. A second editing computer does not require a new recipient
or re-encryption when it uses the same operator key. Each client needs a Cosmos
checkout, SOPS, ssh-to-age, and an independently authorized 1Password CLI.

The current development shell and Bash helper target `x86_64-linux`, so Thoth
and a compatible NixOS gaming host can use the same workflow. Each desktop
needs its own 1Password app/CLI authorization; neither needs a permanently
exported private key. Merely editing secrets does not require importing the
`sops-secrets` NixOS profile or adding that desktop's SSH host recipient. If a
new host later needs its own unattended runtime secrets, add its host recipient
to the shared-file policy and run `sops updatekeys secrets.yaml`; that grants it
access to the entire shared file. Automated configuration builds still
run on Odin, independently of which computer edits the encrypted files.

The development shell supplies pinned SOPS, age and ssh-to-age, and sets
`SOPS_AGE_KEY_CMD` to a checked helper. Thoth also imports the reusable
[`sops-operator`](../features/security/sops-operator.nix) profile, which installs
that helper and sets the callback in the normal login environment. After an
approved rebuild and fresh login, unlock/authorize the 1Password CLI and edit:

```bash
cd /path/to/Cosmos
sops secrets.yaml
```

No manual item-reference export is normally needed. The helper selects exactly
one accessible SSH-key item titled `Cosmos SOPS Operator`, derives its private-key
reference from the vault/item IDs and reads it in OpenSSH format. Missing,
ambiguous, malformed or failed discovery refuses to release an identity. It
pipes `op read` into `ssh-to-age -private-key` without a persistent identity file;
this is not an SSH-agent-only operation: authorized key material enters local
process memory. The callback is not configured on Odin, whose unattended host-key
decryption is unchanged. Do not invoke `cosmos-sops-identity` directly or enable
shell tracing: its stdout is a private identity intended only for SOPS.

An explicit `COSMOS_SOPS_OPERATOR_KEY_REF` remains an optional override, for
example when several operator items are accessible. Copy a secret reference,
not the key value, and include `?ssh-format=openssh`. For Bash:

```bash
export COSMOS_SOPS_OPERATOR_KEY_REF='op://YOUR_VAULT/Cosmos SOPS Operator/private key?ssh-format=openssh'
cd /path/to/Cosmos
nix develop path:. --command sops secrets.yaml
```

For Fish, use `set -gx` instead of `export`. Remove stale manual overrides to
return to automatic discovery. Keep overrides local, not in the repository.
Use the encrypted editor for real values; do not put them in shell arguments,
terminal output, chat or a plaintext file under `/Cosmos`. Before committing,
verify that the saved file contains encrypted values and SOPS metadata. A
private check can discard decrypted output:

```bash
nix develop path:. --command sops decrypt secrets.yaml > /dev/null
```

These editing commands intentionally run on the 1Password client. Automated
Nix evaluation, validation and compilation still run on Odin. The bootstrap
check uses disposable SSH identities and a fake `op` executable to exercise
piped conversion, SOPS roundtrip, refusal paths, three independent recipients
and the single-file policy. It does not authenticate to 1Password or test any
production private key.

The profile sets `sops.defaultSopsFile` to the shared file. Actual secrets must
subsequently be declared by key with explicit ownership/mode in the consuming
service module, using runtime paths such as `/run/secrets/...`,
not decrypted Nix values. Do not grant Hermes the operator identity, host key,
1Password account/session or a blanket secrets group. Keep Odin's SSH host-key
backup secure, retain the operator key in 1Password, and re-encrypt with
`sops updatekeys` before removing or replacing a recipient. Host decryption and
file-permission checks remain post-activation work, with separate approval.

## 1Password service-account bootstrap

Odin's `onepassword-service-account` profile includes `sops-secrets` and declares
one additional SOPS entry, `onepassword_service_account_token`, in the same
repository-wide `secrets.yaml`. The saved token remains in the operator's private
1Password vault; the repository contains only its encrypted deployment copy.
The runtime file is `/run/secrets/onepassword-service-account-token`, root:root
`0400`. As with all entries in this shared file, root on Thoth can also decrypt
it, even though Thoth does not install the token or verification unit.

`onepassword-service-account-verify.service` is a network-dependent oneshot on
Odin, not a GUI integration or a general-purpose application-secret fetcher.
It uses the pinned headless CLI to verify a `SERVICE_ACCOUNT` identity and read
item metadata from `Cosmos Runtime`. Confirm the account has only read-item
access to that dedicated vault in 1Password; the authentication check does not
prove that write permissions are absent. The vault must not contain the operator
private key or the service-account token itself.

Systemd passes the token through `LoadCredential` to a dynamic, unprivileged
user. The unit hides `/etc/ssh`, `/run/secrets` and home directories, uses a
private ephemeral CLI configuration directory, disables caching/debugging/app
integration, and exposes no plaintext token in the unit environment or Nix
store. The helper suppresses provider output, fails on wrong identities or
invalid tokens, and reports only a generic success/failure message. No Hermes
account or agent receives this token.

A network outage, revoked/expired token or inaccessible vault fails the check;
there is no personal-account fallback or persisted-credential fallback. Its
startup timeout is 90 seconds after network ordering. Existing inference
services do not depend on this verifier. Updating the SOPS token restarts the
verification unit during activation; rotating the account remains an explicit
operator task.

The shared unfree-package allowlist composes only the existing NVIDIA,
workstation 1Password and Intel toolkit exceptions, plus `1password-cli` on
Odin. This avoids replacing the Intel exception or enabling all unfree packages.
CI checks preserve each host's license scope and exercise the verifier against
public synthetic fixtures, never the real token or 1Password API.

Activation remains manual and separate. After activating this change, inspect
`systemctl status onepassword-service-account-verify.service`; a successful
oneshot may be inactive with a successful exit status. Do not print the token
file, credential directory or provider debug output. Application-specific
secret fetching will be added only when its consumer and required entries are
specified. No service account is created, modified or rotated by this profile.

## GPU-separated inference with llama-swap

[odin-inference.nix](odin-inference.nix) configures the pinned native
`services.llama-swap`, not Docker or a second always-running AMD server.
After activation the local endpoint remains `http://127.0.0.1:8081/v1`, with the
built-in playground at `http://127.0.0.1:8081/ui/`. Odin overrides the shared
loopback-only frontend default with an IPv4 wildcard listener. The enabled host
firewall allows TCP 8081 only through NetBird's `wt0` interface (localhost still
works); `openFirewall` remains false, so the port is not opened globally or on
the LAN. There is no dependency on the NetBird address being assigned before
the proxy starts. Child servers remain loopback-only on automatically assigned
ports starting at 18081; their listeners and GPU settings are unchanged. The
temporary experiment's listeners on 8090/8091 are not promoted.

The target roster replaces both former Qwen entries with one Radeon Gemma
backend. Configuration review and activation remain separate: the old live proxy
and provisioner still use Qwen until the reviewed replacement is activated.

| API model ID | Context | Slots | Weights / GPU / decoding |
| --- | --- | --- | --- |
| `gemma4-balanced-q4` | 131072 total tokens | 1 | HauhauCS Balanced Q4_K_M; full Radeon Vulkan offload, BF16 GPU projector and separate MTP draft model; up to 3 draft tokens |
| `embeddinggemma2` | 8192 input tokens | 1 | B50 SYCL; Q8_0 text model plus combined BF16 vision/audio projector; 768-dimensional mean-pooled embeddings |
| `clef-flash-q8` | 4096 formatted input tokens | 1 | B50 SYCL; Clef-Flash 9B Q8_0 text-only native decisions, not chat generation |

`gemma4-balanced-q4` is the sole member of `rx-7900xt`, retaining `swap = true`,
`exclusive = false`, and `persistent = true`. It loads on demand, not at startup;
`ttl = 0` disables idle unloading. Group persistence protects it from eviction
by other groups, not explicit unloads or process/service termination. There is
no second Radeon model or separate CPU-vision alias. The separate `intel-b50`
group contains `embeddinggemma2` and `clef-flash-q8`, with `swap = false`,
`exclusive = false`, and `persistent = true`; neither B50 model evicts the other,
and Radeon load/unload operations leave both alone. The startup hook preloads
both B50 model IDs, and `ttl = 0` prevents idle unloading. This does not prevent
explicit unloads or service termination, guarantee recovery of a failed preload,
or pool GPU memory. No Humanizer or KittenTTS model is added. The short
shared-runtime audition observed 13.33 GiB combined process-attributed B50
residency without process swap. This is not a sustained-load or maximum-capacity
guarantee: during mixed requests, embedding median latency rose from about 12 ms
alone to 241 ms, with an 823 ms maximum. Residency isolation does not provide
compute or bandwidth isolation.

### On-demand Radeon Gemma

The selected configuration follows the native Gemma audition:

- Main model on `Vulkan0`, 99 GPU layers (full offload), fit off, `--load-mode mmap`.
- One 131072-token context, parallel 1; 12 generation/prefill threads;
  batch/microbatch 512/256; flash attention on.
- `q8_0` K/V caches for both main and draft. Native `draft-mtp` uses a separate
  draft GGUF on `Vulkan0`, with a maximum of 3 draft tokens.
- BF16 multimodal projector offloaded to `Vulkan0`. The effective production
  image budget is **256 tokens**: native non-causal image attention is capped by
  the microbatch. Do not advertise a 1120-token image budget for these settings;
  raising that budget requires a separately tested configuration and VRAM review.
- Jinja with `--chat-template-kwargs '{"enable_thinking":true}'`; temperature
  0.6, top-k 64, top-p 0.9, min-p 0.05, repeat penalty 1.1; metrics and slots.
- `--cache-prompt --cache-ram 8192 --cache-idle-slots` for host RAM prompt
  snapshots. This is an 8192 MiB budget, not an immediate allocation or a cache
  shared with the B50 models. Explicit unload or process/service termination
  discards the backend's RAM cache.
- No CPU-MoE overrides, forced DeepSeek reasoning format, prompt-similarity,
  lazy-loading or idle-sleep overrides are carried over from the retired models.

Keep system instructions, tool definitions, thinking settings and earlier turns
stable for prefix reuse, and preserve reasoning content when constructing
subsequent turns. Clients must not disable caching with `cache_prompt: false`.
Changing earlier prompt text can still require substantial recomputation. The
response-header timeout remains 1800 seconds for long non-streaming prefills;
context includes formatted input, image tokens, reasoning and output.

The proxy service retains `LimitMEMLOCK=infinity`, inherited by its children;
Gemma's `mmap` mode does not request locking. An allowance is not proof of
residency. Verify actual memory behavior after activation. The shared proxy keeps
request/response body capture disabled.

A native near-full mixed screenshot/text audition passed at 125879 input tokens,
with zero model-process swap. Sampled peak VRAM was 19.761 GiB out of 19.984 GiB,
leaving only 0.223 GiB: this is a narrow tested margin, not a production safety
guarantee. The 512/256 configuration reduced the measured 16K prefill from 9.62 s
to 7.55 s versus microbatch 128; all OCR fixtures passed, with no demonstrated
OCR-quality improvement. In a matched short-text screen using a CPU projector,
MTP maximum 3 measured 133.3 tokens/s, versus 128.1 for maximum 5 and 111.5 without
MTP. Those small synthetic results are not a universal speed claim or a GPU
projector throughput measurement. A long cached follow-up took 8.17 s for 89 new
tokens, and a return after another conversation took 4.47 s for 5 new tokens.
Broad coding/planning and production executor quality remain unvalidated; native
auditions do not establish system-service activation or sustained-load behavior.

### Resident B50 embeddings

The retained model arguments match the conservative audition baseline, with
the shared runtime's FP16 arithmetic enabled:

- Model and combined vision/audio projector explicitly offloaded to `SYCL0`.
- One 8192-token slot; batch and microbatch both 8192. Non-causal embeddings
  require a whole input to fit the microbatch; chat-style microbatch reductions
  are not interchangeable with this configuration.
- Mean pooling, four generation/prefill threads, f32 K/V, flash attention off,
  and `--sleep-idle-seconds -1`. Image token limits remain model defaults.
- `ONEDNN_DEFAULT_FPMATH_MODE=STRICT` and `DNNL_DEFAULT_FPMATH_MODE=STRICT` apply
  only to this model; Intel driver/preemption settings stay in its package
  wrapper, never in the Radeon environment.
- Explicit Nix-managed `--video-ffmpeg-dir` supplies native video decoding tools;
  no frame-rate change is promoted. The pinned helper defaults to 4 fps and has
  no per-request frame cap, so callers must bound clips to the 8K input budget.
  Video samples visual frames; its soundtrack requires a separate audio part.
- The proxy sandbox permits both stable render nodes and allows executable
  writable memory for oneDNN JIT. This relaxation necessarily applies to the
  shared proxy/children; dynamic user, `ProtectHome`, closed device policy,
  read-only model files, and disabled payload capture remain in force.
- Proxy-assigned ports/model IDs replace experimental port 8093; normal service
  logging replaces home-directory debug logs. The experiment's CPU quota is not
  applied to the shared Radeon proxy.

The shared FP16 audition preserved top-1/top-3/top-5 counts of 11/16/16 out of 20
frozen Cosmos questions over 187 chunks. Minimum FP32-reference cosine was
0.9999994 for document vectors and 0.9999891 across the synthetic media controls.
One low-ranked relevant result moved from rank 83 to 84; rankings are not
bit-identical. Existing-index FP32 documents with FP16 query vectors retained the
same top-k counts in this test. Real-media semantic retrieval, native video and
system-service activation remain unvalidated. Flash Attention stays off.

The files come from
[`unsloth/embeddinggemma-2-GGUF`](https://huggingface.co/unsloth/embeddinggemma-2-GGUF)
at revision `031f0d4b35536f69ab3509d4893c923264fcf253`:

| File | Bytes | SHA-256 |
| --- | --- | --- |
| `embeddinggemma-2-Q8_0.gguf` | 309855520 | `6f1bd4ac6c5df7444f9cca7ca36cafe6cfa34cd6f49fefb1e0b4be8143aed8bc` |
| `mmproj-BF16.gguf` | 982074880 | `995aaa56e88b9b631f651861d659b728a625ccc02a238be37cff56cf11dc0032` |

Initial source directory:
`/home/twins/.local/share/cosmos-models/embeddinggemma2/031f0d4b35536f69ab3509d4893c923264fcf253/`.
Provisioned runtime directory:
`/var/lib/llama-models/embeddinggemma2-031f0d4b3553/`. The downloaded Q8 projector
is not required or promoted.

After separately approved activation, a basic text request is:

```bash
curl --fail http://127.0.0.1:8081/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"embeddinggemma2","input":["task: search result | query: Find the Odin inference configuration"],"encoding_format":"float"}'
```

Media uses nested content, for example
`"input":[{"content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,..."}}]}]`.
Audio uses `input_audio` parts and video uses `input_video` parts containing real
media bytes, not filenames or a transcription substitute. API shape support is
not evidence of representative multimodal retrieval quality.

### Resident B50 decisions

Clef retains the tested one-slot 4096-token context, 4096 batch/microbatch,
four generation/prefill threads, full `SYCL0` offload, fit off, attention off,
f32 K/V arguments and no idle sleep. The native decision implementation has no
persistent KV memory; those K/V arguments do not change its FP16 matrix path.
Bound the entire formatted state, questions and options to the input budget.
No vision projector or multimodal Clef serving is promoted.

The shared FP16 build reduced total time for 24 authored decision cases from
51.13 s to 18.47 s, with unchanged 22/24 label agreement and no confidence-gate
changes. Probabilities are not calibrated correctness guarantees. GPT-subscription
workflow savings, sustained mixed load and real agent-task quality remain
unvalidated; deterministic checks and user approvals stay authoritative.

llama-swap's ordinary OpenAI routes do not dispatch `/v1/systemone`. Use its
model-specific passthrough after separately approved activation:

```bash
curl --fail http://127.0.0.1:8081/upstream/clef-flash-q8/v1/systemone \
  -H 'Content-Type: application/json' \
  -d '{"model":"clef-flash-q8","state":"A customer asks for a refund after being billed twice.","questions":{"team":{"type":"choice","instructions":"Select the handling team.","criteria":{"billing":"Charges, invoices and refunds","technical":"Software faults"}}}}'
```

Expect typed `answers` and zero generated output tokens, not a chat explanation.
This adds a serving endpoint, not an integration into the operator's GPT client.

Clef comes from [`ggml-org/Clef-Flash-GGUF`](https://huggingface.co/ggml-org/Clef-Flash-GGUF)
at revision `8aa35d1cc7e141f3771e564eeb630a501597c681`.
`Clef-Flash-Q8_0.gguf` is 9657260192 bytes, with verified SHA-256
`87a232aa1f7495cfc90ce22f08bb3779655e1b05c991c84b21afa4c1c8c4e0f5`.
Its initial source directory is
`/home/twins/.local/share/cosmos-models/clef-flash/8aa35d1cc7e141f3771e564eeb630a501597c681/`;
offline provisioning publishes it under `/var/lib/llama-models/clef-flash-8aa35d1cc7e1/`.

### Runtime artifacts and activation

Gemma's main model, BF16 projector and separate MTP draft model come from
[`HauhauCS/Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-MTP`](https://huggingface.co/HauhauCS/Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-MTP),
pinned at Hub revision `f9093662a2e7ae0503f637088bc96f77a1a70c83`.
The selected artifacts and verified hashes are:

| File | Bytes | SHA-256 |
| --- | --- | --- |
| `Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-Q4_K_M.gguf` | 16796015520 | `3c13133469e431312fffb8b1d9c85ae42199e6bb5746ea1da84e8ddf2097d73c` |
| `mmproj-Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-BF16.gguf` | 1194827776 | `b5346e5bfd906f5e16878c2d0b8243e948ca7410fa28ea35be9b0c54a0ac10b7` |
| `mtp-gemma-4-26B-A4B-it.gguf` | 251937728 | `62bd3af7f66c9308de9a5454233852f8c7324c93767e8dfb824ed45b9179864a` |

Initial source directory:
`/home/twins/.local/share/cosmos-models/gemma4-hauhau-balanced-mtp/f9093662a2e7ae0503f637088bc96f77a1a70c83/`.
Canonical service-readable runtime directory:
`/var/lib/llama-models/gemma4-hauhau-balanced-mtp-f9093662a2e7/`.
A source file must exist for initial provisioning unless its verified destination
already exists; the service does not download weights. Clef and EmbeddingGemma2
retain the pinned artifacts and runtime package documented above.

The `odin-inference-models.service` oneshot runs before llama-swap and provisions
six selected files: Gemma's three artifacts, Clef's text model, and the embedder's
text model and projector. Destinations are revision-specific directories under
`/var/lib/llama-models`. It requests reflinks where supported, checks copied bytes,
and publishes atomically with mode `0444`. Existing destination files are checked,
not overwritten. The dynamic proxy user cannot modify these root-owned files;
`ProtectHome` remains enabled. Once a valid destination copy exists, the source
cache is not needed on later starts. Model files stay outside the Nix store.

Qwen cleanup includes the retired REAP, Swift and checksum-mismatched APEX
weights. Their three user-owned source GGUFs were checksum-checked against the
matching serving copies and removed during preparation (57.629 GiB logical
file size). The three root-owned serving copies remain pending cleanup; copies
may share reflink extents, so logical sizes are not reclaimed-space guarantees.
Do not remove those root copies while the old live proxy or provisioner still
references them: activate and verify the Gemma configuration first. Use a
separately reviewed exact-path inventory, not a broad wildcard removal command.
Root-owned files need root privileges; noninteractive sudo is unavailable.
Removing APEX does not resolve its historical publisher-checksum mismatch.
Unrelated LFM, Humanizer and Kitten files are outside the Qwen cleanup scope.

Run Nix evaluations, validation, and builds on Odin, not on Thoth. Thoth may
edit/stage the changes and drive strict SSH; first transfer the exact pending
files onto a clean, matching feature branch in Odin's `/Cosmos` checkout and
verify their contents. Do not write directly onto Odin's `main` or discard
remote changes. Build completion is not activation permission.

Before activation, obtain separate approval to stop any active temporary backend
and test proxy: experimental processes outside these groups still compete for
GPU memory. The native Gemma audition server listens on port 18110 as `twins`;
its active metadata is
`/home/twins/.cache/cosmos-specialist-tests/gemma4-main-audition/active-audition.json`
on Odin. Before stopping it, validate the recorded PID against the actual
executable and model arguments; do not trust a stale PID or kill by port/name
alone. Stop the verified audition process only with explicit approval, and
confirm that its GPU allocation is released before production activation.
The startup hook preloads both B50 children, so any temporary embedding or Clef
service must also be stopped with approval to avoid duplicate GPU allocations.
Do not infer permission to stop processes or activate from permission to edit,
validate or commit. After those approvals and collision checks, on Odin:

```bash
sudo nixos-rebuild switch --flake path:/Cosmos#odin
systemctl status odin-inference-models.service llama-swap.service
systemctl show llama-swap.service -p LimitMEMLOCK
curl --fail http://127.0.0.1:8081/health
curl --fail http://127.0.0.1:8081/v1/models
```

An idle healthy proxy does not prove backend loading. Confirm `/v1/models`
advertises exactly `gemma4-balanced-q4`, `embeddinggemma2` and `clef-flash-q8`,
with no former Qwen IDs. Before a Gemma request, `/running` should show the two
preloaded B50 children, not an automatically loaded Radeon model. Request
`gemma4-balanced-q4`; verify real text/image generation and native tool calls,
and inspect `/running`. Check its single 131072-token slot, full Vulkan offload,
GPU projector, separate draft model, effective 256-token image budget, memory
behavior and swap usage. Check prompt reuse for appended turns and return visits,
and that an idle model is not unloaded after 600 seconds. These are
post-activation checks, not claims that system-service inference has passed.
The flake check verifies arguments, GPU-specific routing, model paths, service
dependencies and unit syntax; it is not GPU inference.

The proxy's `/api/models/unload` endpoint unloads models but leaves the proxy
available. Both standalone instances remain disabled. The B50 group is independent;
SYCL environment/workarounds are not applied to Vulkan children. After activation,
verify that both B50 models appear in `/running`, the embedder returns valid
768-dimensional text embeddings, and Clef returns typed decisions through the
passthrough URL. Verify both stay loaded while loading, explicitly unloading and
reloading Gemma, and that unloading Gemma discards only its own RAM prompt cache.
These system-service checks are post-activation work, not completed benchmark
results.

### Client access after activation

From an authorized NetBird peer, use Odin's current NetBird IPv4 address:

- Playground: `http://100.94.82.252:8081/ui/`
- OpenAI-compatible base URL: `http://100.94.82.252:8081/v1`
- Clef native decisions: `http://100.94.82.252:8081/upstream/clef-flash-q8/v1/systemone`

Check the current address on Odin with `ip -br address show wt0`; the address is
not hardcoded into the service binding. NetBird policies must also allow TCP
8081 from the intended clients to Odin. The Nix configuration does not modify
those management-plane policies. No SSH tunnel is required for this path.

The UI/API has no application authentication, including model-management and
log endpoints. Restrict NetBird access to trusted clients; do not expose the
port publicly, disable the host firewall, or trust the whole VPN interface as
a substitute for the port-scoped rule. NetBird supplies encrypted transport,
not per-user application authentication.

After manual activation, confirm the frontend listener and localhost health on
Odin, then test from Thoth (not through SSH):

```bash
# On Odin:
ss -ltn 'sport = :8081'
curl --fail http://127.0.0.1:8081/health
# On Thoth, connected to NetBird:
curl --fail http://100.94.82.252:8081/health
curl --fail --output /dev/null http://100.94.82.252:8081/ui/
```

The listener should be `0.0.0.0:8081`, both health requests should succeed, and
the playground should return HTTP 200. Verify a new connection to the LAN
address is still blocked from a LAN client. These are post-activation checks,
not results implied by evaluation or a build.

An SSH tunnel remains optional for clients with an authorized SSH key:

```bash
ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:8081:127.0.0.1:8081 twins@100.94.82.252
```

Then use `http://127.0.0.1:8081/v1` and `/ui/` on that client. Brother-specific
SSH authorization remains separate work.

Routine approved updates use `sudo nixos-rebuild switch --flake path:/Cosmos#odin`.
Never run Disko formatting for routine updates.

## Local Honcho storage and container runtime

[`honcho-local`](../features/agents/honcho-local.nix) provides native storage.
[`honcho-runtime`](../features/agents/honcho-runtime.nix) extends that profile
with the API and worker; a successful build does not activate them or enable
Hermes memory integration:

- Native PostgreSQL 17 with the separately packaged `pgvector` extension. The
  bundled PostgreSQL contrib extensions `pg_trgm` and `btree_gin` do not require
  additional Nix packages.
- A database and non-superuser owner named `honcho`; no role/database creation
  or replication privileges. A dedicated, non-login system account supplies the
  rootless container identity, without adding privileges to Hermes. Odin pins
  its already allocated UID 992 so native rootless OCI/user-manager units have
  a stable runtime path; no existing state UID is changed.
- Unix-socket-only database access with peer authentication; not even a loopback
  TCP listener. No database port is opened in the firewall.
- Idempotent [extension SQL](../../packages/honcho-database.sql) applied as
  `postgres` after the native `postgresql-setup.service` creates the database and
  role. Honcho itself does not need PostgreSQL superuser privileges.
- Rootless Podman support, subordinate UID/GID ranges and lingering for the
  dedicated account. No Docker daemon, Docker compatibility alias or agent
  membership in privileged container-management groups.

Honcho 3.4.0's migrations require `vector`; `pg_trgm` accelerates message search
and `btree_gin` accelerates queue indexing. All three are enabled. The narrowly
scoped `mkForce` for `listen_addresses` is necessary because the pinned NixOS
module otherwise assigns `localhost` even when `enableTCPIP` is false.

The [database check](../../tests/honcho-database.nix) uses only a disposable
cluster and synthetic facts: extension creation, vector search, both index
types, restricted role privileges, peer-authentication refusal and restart
persistence. Its temporary trust authentication is not the deployed policy.

Apply this configuration only through a separately approved Odin rebuild.
After activation, verify the real `postgresql.service` and
`postgresql-setup.service`, extension availability in the `honcho` database,
role restrictions and absence of a TCP listener.
Database installation does not prove Honcho extraction or recall works.

The official [Honcho image](../../packages/honcho-image.nix) is exposed as
`packages.x86_64-linux.honcho-image` and retained in Odin's system closure through
`system.extraDependencies`. Nix fetches the Linux/amd64 3.4.0 archive using both a
fixed registry digest and a separately verified archive content hash, with TLS
verification enabled. There is no moving `latest` tag or activation-time registry
pull. On Odin, it can be built independently with:

```bash
nix build --no-write-lock-file --no-link --print-out-paths path:/Cosmos#honcho-image
```

This command alone only builds the archive. The declarative OCI units use it
through `imageFile`, with the archive-local name
`ghcr.io/plastic-labs/honcho:3.4.0` and `pull = "never"`. The
[image check](../../tests/honcho-image.nix) validates the archive platform/tag,
packaged application version and generated runtime policy without starting it.

Enabling Podman also generates `/etc/containers/policy.json`, `registries.conf`
and `storage.conf` through the native NixOS containers module. These files appear
on the live host only after activating this configuration. Do not hand-write a
personal policy or disable TLS checks to work around an unactivated runtime.
The default image policy permits unsigned images; the fixed digest and Nix
archive hash provide content pinning, not publisher-signature verification.

### Application, authentication and local inference

`podman-honcho-api.service` and `podman-honcho-worker.service` run the official
image as the native `honcho` identity. The image's app UID 100/GID 101 is mapped
to that identity with `keep-id`, preserving PostgreSQL peer authentication.
The containers have read-only root filesystems, no added capabilities or GPU
devices, and only the database socket plus immutable startup/tokenizer files
mounted. Host networking permits the private Unix socket and loopback model
interfaces without publishing ports; Uvicorn explicitly binds `127.0.0.1:8000`.

API startup runs upstream migrations, then `configure_embeddings.py --yes`
before serving. Upstream initially creates 1,536-dimensional columns; the
configuration tool aligns empty tables to EmbeddingGemma's 768 dimensions.
It is a no-op at the matching dimension and refuses to alter populated
embedding columns at another dimension. Do not work around that refusal by
dropping data. The API uses conmon's container notification and a bounded,
credential-free systemd `ExecStartPost` health poll. The worker waits for that
poll, not merely container creation. This avoids the observed Podman health-timer
startup failure; it is a startup gate, not continuous health monitoring.

`honcho-credentials.service` generates a local signing key on first activation
in root-only `/var/lib/cosmos-honcho` (0700 directory, 0600 files). It preserves
the key across restarts and refuses malformed/link-unsafe state or an absent key
when credential outputs already exist. Systemd reads the root-only server
`EnvironmentFile` before filesystem namespace setup; Podman inherits
`AUTH_JWT_SECRET` by name, never as a literal Nix or command-argument value.
Do not pass a per-unit `/run/credentials/...` environment-file path into rootless
Podman: its shared mount namespace can see the API's credential mount but not the
worker's. The server key remains in the dedicated process/container environment,
not Hermes's. The Hermes client JSON still uses protected `LoadCredential`
publication. The private `client.json` contains a token scoped only to the `personal`
workspace, never an admin token. The Hermes integration publishes only this
client configuration, not the signing key or server environment. No new SOPS entry or operator credential
is needed for this locally generated service identity. Back up the signing state
securely with the database before relying on stored memory.

Every extraction, summary, dream and dialectic model configuration explicitly
uses the local Gemma model, with no fallback. Dreaming and Redis caching are
disabled initially; derivation is a single background worker. The fixed local
inference interfaces are `127.0.0.1:18094` for Gemma chat and
`127.0.0.1:18093` for text-only `embeddinggemma2` embeddings. They refuse model
management and caller-selected upstreams. The shared HTTP core retains the
existing Hermes listener's chat-only policy; this adds no Hermes endpoint access.

Honcho's tokenizer data is separately hash-pinned by
[`honcho-tokenizer-cache.nix`](../../packages/honcho-tokenizer-cache.nix).
The container receives actual data files, not store symlinks whose targets are
outside its mounts, and can initialize both required encodings with networking
disabled. Sentry, telemetry and payload tracing are explicitly disabled.
`cosmos-honcho-egress.service` atomically installs a separate UID policy allowing
only the API and these two model interfaces on IPv4 loopback, plus loopback reply
traffic. Direct model-management access, DNS, other loopback ports, IPv6 and
external egress are denied. Stopping its controller does not remove the policy;
retirement requires stopping every Honcho-owned process before separately
removing `inet cosmos_honcho`. Never flush the host ruleset.

Container logs use Podman's bounded private file logging inside the account's
0700 home, rather than the system-wide journal readable by Hermes. Treat those
logs, memory tables, generated signing state and backups as sensitive. Odin's
disk remains unencrypted and no memory-backup policy is established yet.

### Hermes memory integration

The reusable [hermes-honcho](../features/agents/hermes-honcho.nix) profile selects
`memory.provider: honcho`. The [client package](../../packages/hermes-honcho-plugin.nix)
pins the official catalog plugin to `e2d2aba182862deeb846e5cd4a30a41bce0ed82a`
and the official `honcho-ai` SDK to 2.2.0. The plugin is copied into Hermes's
immutable provider package; the SDK uses the sealed runtime's compatible
dependencies. There is no activation-time pip install or mutable plugin clone.
Honcho's server and worker still run exclusively in the official OCI image.
The host Python files provide credential publication, a fixed-model inference
boundary and startup/readiness glue; they do not reimplement the Honcho server.

`hermes-state-setup` loads the root-generated client JSON through systemd
`LoadCredential` and publishes root:hermes `0640` `honcho.json` in the protected
managed home. Its original source must be a root-owned, single-link `0600`
regular file beneath trusted no-follow ancestors, and must match the credential
copy. The agent can read its workspace token but cannot replace the configuration
or read signing state. No credential bytes enter Git, Nix derivations or arguments.

The single-user identity is `twins`, the assistant identity is `hermes`, and the
workspace is `personal`. Per-session conversations share the pinned user peer;
this strategy also skips the plugin's automatic memory-file migration. There is
no bulk historical import. Recall is hybrid, capped at 1,200 context tokens, with
context cadence 1, dialectic cadence 5 and one low-capped reasoning pass.
Writes and backend extraction are asynchronous: a correction may not be reflected
in an immediate recall. Existing transcripts remain stored; forgetting a derived
conclusion alone is not erasure of the source conversation or a backup policy.

Hermes gains only IPv4 loopback API port 8000 when Honcho is selected. It still
cannot reach PostgreSQL, the Honcho inference listeners, direct model management
or external services. Neither its groups nor container authority change. Both
Hermes units order initial startup after API readiness, but do not require the
memory service to remain available for basic chat.

### Activation boundary and acceptance

After a reviewed, separately approved Odin rebuild, inspect only service status
and the public health endpoint initially:

```bash
systemctl is-active honcho-credentials cosmos-honcho-egress cosmos-honcho-inference \
  podman-honcho-api podman-honcho-worker
curl --fail http://127.0.0.1:8000/health
ss -ltn 'sport = :8000'
```

The listener must be IPv4 loopback-only. Do not paste credential files, container
environment/inspect dumps or raw application logs into chat. Privileged live
acceptance must check peer identity, authenticated requests, scope isolation,
UID egress and restart recovery without exposing keys or existing memory.

[`honcho-runtime.nix`](../../tests/honcho-runtime.nix) checks configuration and
synthetic credential/startup/inference fixtures. The separate
[`honcho-egress.py`](../../tests/honcho-egress.py) exercises the actual rule text
inside a verified unprivileged user/network namespace, never on the host firewall.
Disposable OCI/database acceptance uses only public synthetic facts; it is not
proof that the native production units are active. The
[Hermes check](../../tests/hermes-honcho.nix) verifies provider discovery/import,
SDK requirements and private credential publication. The separate
[provider fixture](../../tests/hermes-honcho-provider.py) requires an explicitly
marked disposable home and exercises real hooks and reasoning tools, not a mock
API. After activation, verify actual authenticated dashboard chat can learn a
public sample preference, recall it in a new chat, apply a correction after
extraction catches up, and retain it after an approved service restart. Check
native-unit recovery separately; container-only restart is not that proof.
Use a separately approved deletion scope for real memory, never test erasure by
deleting the existing `personal` workspace. Do not paste memory or credentials
into diagnostics.

## OpenConcho memory inspection

The reusable [openconcho profile](../features/agents/openconcho.nix) adds the
published upstream OpenConcho **0.17.1** web image in rootless Podman. The image
registry digest and Nix archive hash are pinned in
[openconcho-image.nix](../../packages/openconcho-image.nix); activation loads the
retained archive with `pull = "never"`. The frontend bundle is not forked.

After separately approved activation, browse **http://100.94.82.252:9120/** from
an authorized NetBird peer. nginx binds that address plus loopback for readiness;
the firewall permits port 9120 only on `wt0`. NetBird management policy must also
allow the intended peer. Honcho remains on `127.0.0.1:8000`, not a NetBird/public
API listener.

The browser first presents an HTTP Basic login. The username is `viewer`; its
random password is generated once and kept in root-only
`/var/lib/cosmos-openconcho/login.json`. Inspect that file privately on Odin with
`sudo less /var/lib/cosmos-openconcho/login.json`, then save the password in the
operator's password manager. Do not paste it, the file, or a Podman inspect/env
dump into chat. The file also contains the verifier; never publish it. The helper
preserves an existing valid login and refuses unsafe/corrupt state rather than
silently resetting it. No shared SOPS file or existing dashboard login is changed.

The preconfigured instance URL is `http://127.0.0.1:8000`; leave OpenConcho's own
API-key field empty. Web requests use the same-origin `/api/` proxy, so this URL
refers to nginx's local backend, not the workstation browser's localhost. nginx
injects a private Honcho **admin JWT** server-side because stock workspace
discovery requires admin authentication. It ignores browser-selected upstream
headers. The JWT is not in the SPA, config.js or browser storage; the signing key
is never mounted into the container. The browser login is a name, **not a
read-only permission role**: normal OpenConcho mutation/management controls remain
available. The intended usage is inspection, not enforced read-only access.

A separate `openconcho` service identity (UID 991) owns its private Podman home.
It has no database socket, signing key, GPU devices, Hermes group or container
administrator access outside its own rootless engine. A root-only oneshot derives
the UI token from the existing Honcho key without changing that key or Hermes's
workspace-only credentials. systemd reads a private `container.env` and Podman
inherits values by environment-variable name, avoiding per-unit credential mounts
inside rootless Podman's shared mount namespace. nginx receives only the backend
token and login hash; plaintext login passwords do not enter Podman.

The UID firewall allows the local API, loopback readiness and inbound replies,
plus the same exact marked NetBird transport exception as Hermes. Other outbound
TCP, direct model access and database TCP are denied. The browser CSP restricts
connections to the same origin and blocks remote image loading. nginx does not
log requests; container errors use bounded files inside the private Podman home.
The container root filesystem is read-only with writable temporary storage; this
filesystem setting does not make Honcho API operations read-only.

Validation includes the [flake contract](../../tests/openconcho.nix), synthetic
[credential tests](../../tests/openconcho-credentials.py), and separate
[real-image fixture](../../tests/openconcho-runtime.py). The latter runs as the
unprivileged Odin operator, uses a fresh PostgreSQL database and both real OCI
images, and checks login gating, upstream assets, browsing messages/conclusions,
writable API proxying and UI-container restart recovery. It never uses the
production memory database. These are not proof of post-activation browser access.

After an approved rebuild, check:

```bash
systemctl is-active openconcho-credentials cosmos-openconcho-egress podman-openconcho
curl --fail http://127.0.0.1:9120/healthz
curl --silent --output /dev/null --write-out '%{http_code}\n' http://100.94.82.252:9120/
ss -ltn 'sport = :9120'
```

The unauthenticated UI status must be `401`; health is public and contains no
memory. Verify browser login and the existing `personal` workspace from Thoth
separately. Do not test editing/deletion against real saved memory. Honcho and
Hermes do not depend on the UI remaining available.

## Fresh local Hermes deployment

[odin-hermes.nix](odin-hermes.nix) composes the reusable
[hermes-local](../features/agents/hermes-local.nix) profile. This is a fresh
service account and state tree, not an import of Thoth's Hermes installation.
Evaluation, package builds and fixture tests are not proof of live deployment.

### Identity, network and credentials

The native `hermes-agent` gateway owns durable dispatch; `hermes-backend` serves
an authenticated dashboard on port 9119, bound to the IPv4 address of `wt0`.
The firewall opens that port only on `wt0`. NetBird management-plane policy must
also permit the intended operator peers. No public listener, external OAuth
provider, cloud model credential or automatic GPT fallback is configured.

The `hermes` account has journal-reading membership but no wheel, container-engine
administration, root SSH or Nix-daemon access. Odin's Nix allowed-users are root
and wheel operators: a privileged network-enabled builder must not become the
agent's egress proxy. Personal homes, the user-manager bus, system bus, resolver/NSS
and Nix-daemon sockets are hidden from both services. Lingering is disabled and a
`user@.service` guard denies this account a separate user manager. Native Kanban
contacts its profile owner directly; it does not need a user-bus mount. Writable
data and proposals live under `/var/lib/hermes`; the checkout remains read-only.

The state parent is root-owned `0750`; `.hermes` is root:hermes `3770` (sticky,
setgid, private-group writable). Root-owned policy/credential files cannot be
replaced by the agent, while its data directories and new runtime files remain
writable. A dedicated root oneshot runs with the private service group and only
`CAP_CHOWN`, `CAP_FOWNER` and `CAP_DAC_OVERRIDE`. It never forks or switches UID/GID.
Each consumer's `ExecStartPre` runs `--prepare-data` as the service user inside that
consumer's full sandbox, preparing `logs/curator` without credentials or policy
publication. Root does not enter this nested mutable log directory.

Root provisioning uses anchored no-follow descriptors and atomic publication, and
checks actual owner/group/mode after changing privileged directory metadata. It
rejects hostile symlinks/hardlinks instead of recursively chowning agent-controlled
trees, and fails if Linux silently strips a required mode bit. It preserves
existing data. The Odin-only package patch
accepts this exact managed-home shape with trusted ancestry and a private group;
it retains same-UID socket ownership and kernel peer-credential authentication.
The shared upstream pin and Thoth package are unchanged.

`cosmos-hermes-egress.service` installs an independent nftables table without
changing the existing firewall backend. The rule covers the Hermes UID, including
detached processes: new TCP traffic may reach only `127.0.0.1:18090` (inference)
and `127.0.0.1:18092` (the authenticated local-owner RPC API), plus
`127.0.0.1:8000` only when the Honcho provider is selected. A separate IPv4 rule
permits port 9119 only when the kernel routing table identifies the destination as
local to this host. The dashboard PTY and sidecar use that authenticated callback
to their own dashboard listener, including its NetBird address; a remote peer on
port 9119 is not allowed. Reply traffic is retained for inbound dashboard sessions.
Kernel WireGuard can preserve the application socket UID on the encrypted UDP
packet while resetting its conntrack metadata. The inner TCP reply may pass but
its encrypted outer packet can still reach the UID reject rule, depending on
which peer originated the UDP transport flow. A narrow exception therefore
accepts only IPv4 UDP with NetBird's exact privileged control-plane mark
`0x1bd00`, its declared source port (58120), physical output interface `enp4s0`,
and a non-local destination. This does not allow unmarked UDP, data-plane marks,
other source ports, loopback/proxy destinations or arbitrary outbound TCP.
Hermes has neither `CAP_NET_ADMIN` nor `CAP_NET_RAW`, so it cannot set this mark.
The mark matches the pinned NetBird default and checked live routing rule; a
transport interface/port/mark change requires reviewing this fail-closed policy.
No NetBird daemon configuration change is required.

The separate [kernel WireGuard fixture](../../tests/hermes-wireguard-egress.py)
runs only as the unprivileged Odin operator in verified disposable user/network
namespaces. Point its `HERMES_TEST_RULES` at the generated policy, supply pinned
`HERMES_TEST_NFT`/`HERMES_TEST_WG` tools and a private `HERMES_TEST_OUTPUT_DIR`.
Green uses the actual rule; red removes only the exception. Test both server-
and peer-originated transport flows plus rejected lookalike UDP and unrelated
outbound TCP. Loopback-only tests cannot cover this encapsulation boundary.

Native queue clients obtain a short-lived ticket over their private Unix socket,
then connect to the fixed loopback owner API; arbitrary loopback ports remain
denied. The policy is ordered before
network setup and required by both Hermes services. Stopping its controller does
not remove the table; when retiring this feature, stop every same-UID worker
before separately removing `inet cosmos_hermes`. Do not flush the host ruleset.

`cosmos-hermes-inference.service` exposes only the selected Gemma model and chat
inference. It rejects management/passthrough routes, alternate models, remote/file
image URLs and unbounded generation. It forwards inline images and streaming,
pins the agreed sampling, and does not log request bodies. Hermes cannot directly
reach llama-swap's management API. This is a narrow interface, not a general HTTP
proxy. Backend unavailability must fail locally, never switch to a cloud model.

The single shared `secrets.yaml` contains encrypted `hermes_dashboard_env`.
Only Odin receives its root-only runtime file. `hermes-state-setup` receives a
systemd `LoadCredential` copy after SOPS provisioning, then atomically publishes
root:hermes application policy and environment files; the agent never reads the
SOPS directory or its host decryption identity.
The raw dashboard password is stored in the operator's 1Password login named
`Odin Hermes Dashboard`, in `Cosmos Runtime`, not in the repository or Nix store.
There is no static dashboard session-token file. Changing a password does not
revoke already signed Basic-auth sessions; rotate the signing secret to do that.

The operator-only [credential bootstrap](../../packages/hermes-dashboard-bootstrap.py)
uses the authorized SOPS callback on an editing client, passes values over stdin,
and verifies the 1Password item and decrypted target privately. It refuses an
implicit rotation when the SOPS entry already exists. Never invoke it as Hermes,
print the identity callback, or put a password/hash/signing key in shell arguments.

### Durable task workflow

The gateway owns Kanban dispatch with one in-progress task and an explicit
`default` assignee allowlist. `HERMES_HOME` and `HERMES_KANBAN_HOME` refer to the
same fresh state tree. Automatic decomposition and review dispatch are disabled;
local memory and skill updates do not need repeated interactive approval.
Shell approval prompts are disabled only for this constrained service account.
This grants no host-administration rights or GPT-handoff authorization.

Use the dashboard's Kanban task interface, or ask the chat agent to enqueue the
work and report its task ID. A browser chat/PTY or a background subagent alone is
not the durable-work contract. A task needing additional authority must save its
partial result and enter Blocked with an actionable reason, not leave a live
approval dialog waiting to expire. Current configuration does not implement a
privileged-action broker or approved GPT handoff path.

For an operator CLI task, run the built Hermes binary as the service user with
both state variables pinned. Example Bash, after separately approved activation:

```bash
hermes_bin=$(systemctl show --value --property=ExecStart hermes-agent.service)
hermes_bin=${hermes_bin#*path=}
hermes_bin=${hermes_bin%% ;*}
case "$hermes_bin" in
  /nix/store/*/bin/hermes) ;;
  *) printf '%s\n' 'Unexpected Hermes executable; inspect the unit.' >&2; exit 1 ;;
esac
sudo -u hermes env \
  HERMES_MANAGED=nixos \
  HERMES_HOME=/var/lib/hermes/.hermes \
  HERMES_KANBAN_HOME=/var/lib/hermes/.hermes \
  "$hermes_bin" kanban create \
  'Inspect the local workspace and save findings' \
  --assignee default --workspace dir:/var/lib/hermes/workspace \
  --completion-contract local-only --max-runtime 30m --json
```

The service package is deliberately not installed globally and does not export
`HERMES_HOME` into the operator's shell. The example discovers its store binary
from the active unit; do not use another user's profile or runtime. This is only
an operator queue-submission command: do not launch interactive agents, workers,
`dispatch` or `daemon` this way outside the system service sandbox.

### Activation and acceptance

After reviewing and validating the matching checkout, approved activation uses
the normal Odin rebuild command above. Then verify:

- Both Hermes units, the UID policy and inference gateway are active.
- Unauthenticated dashboard requests are gated; the Basic provider is available,
  and password login works from an intended NetBird peer. No LAN listener exists.
- A real Hermes request reaches Gemma through the narrow interface, including a
  tool round-trip and an uploaded image; a local outage does not route externally.
- The service UID cannot reach the direct model API, public network, operator
  home, private keys, SOPS runtime credentials or the Nix daemon.
- A queued task continues after closing the browser. Test worker/gateway restart
  recovery, saved results and a persistent Blocked task without repeating actions.

The flake check validates configuration and synthetic HTTP/hash fixtures. The
[namespace test](../../tests/hermes-egress.py) checks the generated packet policy
inside a disposable unprivileged user/network namespace; it never changes the
host firewall. These do not replace the post-activation checks above.

Notifications, off-host backups, remote-host collectors and privileged actions
remain separate rollout steps. A local state directory is not an off-host backup.
