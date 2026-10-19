# Thoth: ThinkPad T490

This is the single host guide for [thoth.nix](thoth.nix). Repository structure and contributor rules live in [README.md](../../README.md) and [AGENTS.md](../../AGENTS.md). Commands below are procedures, not evidence that they have just been run. Agents need explicit permission for deployment, installation, disk changes, hardware-report regeneration, and power-state changes.

## Configuration and status

| Area | Declared configuration |
| --- | --- |
| System | Pinned `nixos-unstable`, `x86_64-linux`, user `twins`, Fish; `system.stateVersion = "26.05"` |
| Storage | GPT, 2 GiB FAT32 ESP, LUKS container `cryptroot`, LVM VG `nixos` |
| Logical volumes | Bcachefs `root`, persistent 32 GiB `swap` |
| Boot/resume | systemd-boot, systemd initrd with LVM, `/dev/nixos/swap` |
| Desktop | greetd/tuigreet session chooser, Niri and experimental Mango, PipeWire, Bluetooth, LXQt Polkit |
| Network | NetworkManager, resolved, firewall, OpenSSH, NetBird `wt0` |
| Credentials | 1Password desktop/CLI and SSH agent |
| State | Persistent root; no ZFS, impermanence, or automatic root rollback |

Existing documentation records a completed encrypted-LVM reinstall and a successful manual hibernate/resume test restoring Niri. That historical test does not prove current runtime health or the timed suspend-to-hibernate transition. The layout accommodates the documented 16 GiB RAM and planned 24 GiB upgrade; repeat resume testing after hardware changes.

Sources of truth:

- [Host composition](thoth.nix): profiles, user, boot/resume settings, Hermes CLI/Desktop.
- [Disk layout](../../disk-layouts/thoth.nix): target device and generated filesystem/swap configuration.
- [Hardware report](../../hardware/thoth/facter.json): the tracked real T490 Facter report.
- [Base features](../features/base.nix), [CLI tools](../features/cli-tools.nix), and [workstation](../features/workstation.nix).
- [Shared desktop](../features/desktop/base.nix), [applications](../features/desktop/apps.nix), and [Polkit agent](../features/desktop/polkit-agent.nix): contributions to `base-desktop`.
- [Niri](../features/desktop/niri.nix), [Mango](../features/desktop/mango.nix), and [1Password](../features/security/onepassword.nix).
- [Login/session chooser](../features/desktop/tuigreet.nix): greetd and tuigreet.
- [Power policy](../features/power/laptop-sleep.nix), [NetBird](../features/netbird.nix), and [SSH](../features/ssh.nix).

## Packages, services, and session behavior

Use the Nix modules above as the authoritative package inventory rather than maintaining a second exhaustive list. Hermes CLI and Desktop are installed from the pinned Hermes flake, with no persistent gateway service declared; runtime authentication, sessions, and memory stay outside Git in `~/.hermes`.

Thoth composes `base-desktop` independently of `niri-desktop` and `mango-desktop`. The shared profile supplies graphics, PipeWire ALSA/PulseAudio, RTKit, Polkit, Bluetooth, dconf, GNOME Keyring, GVfs, UDisks2, Tumbler, fonts and desktop applications. Niri and Mango remain enabled; greetd/tuigreet supplies login and `workstation` supplies NetworkManager. SDDM is not enabled. The LXQt Polkit agent and shared `swayidle.service` follow `graphical-session.target`; the locker is declared for both Niri and Mango, with a Wayland-environment guard.

Optional packages do not necessarily autostart. Mango starts the packaged Waybar and Mako services and the awww daemon with its session; this does not add Niri autostart. Cosmos does not declare custom Niri `config.kdl`, keybindings, themes, Waybar styling, wallpaper selection, or user units for clipboard utilities. Home Manager is not activated. Installing TLP, Flatpak, or Podman does not mean their services/integrations are enabled. GNOME Keyring's service is explicitly enabled by `base-desktop`; unlocking and application integration still require runtime verification. Clipse is the selected clipboard-history package and Crosspipe the included audio-routing application; do not assume alternatives are installed. Niri upstream defaults commonly use Super+T for Alacritty and Super+D for Fuzzel, but Cosmos does not declare those bindings itself.

NetBird's named client and interface are both `wt0`, with UDP port `58120`, autostart, hardened mode, and firewall options enabled. Startup alone does not prove enrollment or peer connectivity. OpenSSH uses `openFirewall = true` and is **not restricted to NetBird**. Establish and test NetBird access before tightening SSH exposure.

The shared profile disables NetBird's embedded SSH server with
`config.ServerSSHAllowed = false`; use normal `ssh` over the VPN with OpenSSH
authentication. NetBird SSH's JWT/password prompt does not accept the Linux user
password. See [Odin's migration procedure](odin.md#migrating-from-embedded-netbird-ssh)
for existing peers and host-key verification when replacing the embedded server.

1Password provides SSH identities at `~/.1password/agent.sock`; the OpenSSH client sets `IdentityAgent` system-wide and the built-in SSH agent is disabled. The GUI must be running with Settings → Developer → Use the SSH agent enabled. A refused connection can mean the agent has no socket listener. Its unfree allowance is narrowly declared in the workstation security feature.

## Login and desktop selection

The `tuigreet-login` profile runs greetd on VT1 with an explicit, store-qualified
tuigreet command as the unprivileged `greeter` user. `useTextGreeter = true` applies
the NixOS module's TTY settings and sends errors to the journal rather than
overlaying the login prompt. No autologin/`initial_session` is declared.

Tuigreet reads the NixOS-generated Wayland session directory, containing Niri and
Mango. X11 entries, if added later, are passed separately through `--xsessions`.
Press **F3** (or Fn+F3 if firmware maps the key to a media action) to select a
desktop, then authenticate. No `--cmd` or forced desktop environment is supplied:
the selected desktop entry provides its command, desktop names and session type.
Niri's entry runs `niri-session`, preserving its systemd session and sleep locker.
Tuigreet remembers the username and each user's selected session using
`--remember --remember-user-session`. With no remembered selection it picks the
first session alphabetically (currently Mango). Use F3 to choose either desktop;
verify the shared locker in each before relying on sleep locking.

After an explicitly approved deployment and logout/reboot, verify the actual
login prompt, both F3 entries, Niri login/logout and return to the prompt. Do not
restart the active display manager to test it during an unsaved desktop session.
From a separate TTY, these read-only **Fish** diagnostics identify greeter errors:

```fish
systemctl status greetd.service --no-pager
journalctl -b -u greetd.service --no-pager
```

`default_session contains no command` means greetd could not launch any greeter;
it is not evidence of a kernel/storage boot failure. Keep the configured command
nonempty and use the generated session directory, not an assumed global path.

## Mango: experimental second session

The `mango-desktop` profile uses `programs.mango.enable` from the pinned root
nixpkgs. It installs Mango, registers its `mango` login session and supplies GTK/wlr
portal configuration. No separate Mango flake, overlay or Home Manager activation
is needed. Choose Niri or Mango from tuigreet; no autologin is enabled.

This is the initial package/session stage, not a fully integrated daily desktop.
The `base-desktop` profile supplies shared desktop packages and services without depending on either compositor. Niri's profile now contains only Niri and XWayland Satellite; retain the shared profile when removing or replacing a compositor.
Cosmos declares a minimal fallback at `/etc/mango/config.conf`: Super+Return opens
Alacritty, Super+D opens Fuzzel, Super+Escape requests a manual Swaylock,
Super+Shift+Q exits, Super+Q closes a window, Super+R reloads, Super+Tab cycles
focus, Super+N cycles layouts and Alt+arrows change directional focus. Existing
`~/.config/mango/config.conf` or `config.toml` takes precedence and is not modified.
The fallback avoids Mango's upstream foot/rofi bindings without adding applications.

The profile registers Mango's shipped `mango-session.target`. Mango itself imports
the Wayland activation environment and starts that target, which binds to
`graphical-session.target`; it also requests graphical-session shutdown on exit.
There is no `mango.service` or custom session wrapper. Verify that the LXQt Polkit
agent, portals and environment actually start/stop correctly when switching
sessions. The packaged Waybar and Mako units are wanted by `mango-session.target`,
start only with a Wayland environment, and stop with `graphical-session.target`.
No separate `exec_once=waybar` or `exec_once=mako` entries are needed in the user
config. Mako retains its D-Bus notification service and user configuration. Waybar
uses its packaged configuration unless overridden by the user; Mango-specific
modules and styling and a fuller desktop configuration remain undeclared.

The shared desktop profile installs `awww`; Mango declares `awww.service`, running
`awww-daemon` in the foreground. It starts with and stops with
`mango-session.target`, requires `WAYLAND_DISPLAY`, and restarts on failure.
Do not add a duplicate `exec_once=awww-daemon` to the Mango config. No wallpaper
path is declared; awww restores its cache when available. After deployment and
a fresh Mango login, check and select an image with these **Fish** commands:

```fish
systemctl --user status awww.service --no-pager
journalctl --user -b -u awww.service --no-pager
awww img /path/to/wallpaper.png
```

**Sleep locking:** `laptop-sleep` declares one shared `swayidle.service` for both
compositors through `graphical-session.target`, not a Niri-specific service.
This fixes the declared session dependency, not proof of runtime protection.
Do not rely on Mango or Niri locking before sleep until the reviewed configuration
is deployed and the [locking checks](#sleep-locking-and-hibernation) pass in both.
Lid-triggered and low-battery hibernation remain active; keep the lid open and AC
connected during supervised bring-up and do not change power policy silently.

After a reviewed build and explicit deployment approval, log out of Niri and
select Mango with tuigreet's F3 menu for a supervised trial. Return to Niri through
the same menu if Mango is not usable; this does not replace Niri or its configuration. Deployment,
logout and runtime testing have not been performed merely by adding the module.

Before promoting Mango to a daily desktop:

- Exercise the fallback terminal/launcher, exit and manual-lock bindings in-session.
- Integrate session environment/lifecycle, the Polkit agent and portal activation;
  verify file dialogs, screen sharing and XWayland in the actual Mango session.
- Verify the shared before-sleep locker starts/stops with each session without
  duplicate listeners or stale environment across compositor changes.
- Test manual lock, approved suspend/hibernate and logout/login in both desktops,
  including stopping the old session's services and preserving Niri behavior.

## Local speech: packaged Piper

The [local TTS feature](../features/local-tts.nix) installs nixpkgs's Piper CPU
CLI and GNU Time. Training, HTTP-server and alignment extras are disabled through
the package's supported overrides. Hermes CLI/Desktop packages and their sealed
Python dependencies are unchanged. There are no KittenTTS dependencies, custom
upstream patches, services, activation scripts or declaratively managed profiles.

After explicit deployment approval, use the routine non-storage update procedure
below. Voice downloads and inference tests are separate post-deployment steps.
The initial voice is `en_US-lessac-medium`: approximately **60.3 MiB** for its ONNX
model and JSON config, stored in a user-writable cache outside Git/the Nix store.

### Download and verify the voice (after approval)

Run these **Bash** commands as `twins`. The pinned revision and hashes identify
the exact voice files; do not overwrite an existing voice without reviewing it.

```bash
voices="${XDG_CACHE_HOME:-$HOME/.cache}/piper-voices"
mkdir -p "$voices"
base='https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/lessac/medium'
for suffix in onnx onnx.json; do
  file="$voices/en_US-lessac-medium.$suffix"
  if [[ -e "$file" || -L "$file" ]]; then
    printf 'Keeping existing file; verify its hash: %s\n' "$file"
  else
    curl --fail --location --output "$file" "$base/en_US-lessac-medium.$suffix"
  fi
done
printf '%s  %s\n' \
  5efe09e69902187827af646e1a6e9d269dee769f9877d17b16b1b46eeaaf019f "$voices/en_US-lessac-medium.onnx" \
  efe19c417bed055f2d69908248c6ba650fa135bc868b0e6abb3da181dab690a0 "$voices/en_US-lessac-medium.onnx.json" \
  | sha256sum --check
```

Stop on any download/hash failure. Package-build validation does not run these
commands or download voices. Cached local paths require no cloud inference or
paid API, and Piper defaults to CPU unless `--cuda` is explicitly requested.

### Offline samples and timing (after approval)

Keep Thoth on AC with its lid open and other CPU-heavy work idle. These **Bash**
commands generate identical short/long samples across three repetitions, saving
audio and elapsed/user/system CPU time, CPU percentage and peak RSS:

```bash
voice="${XDG_CACHE_HOME:-$HOME/.cache}/piper-voices/en_US-lessac-medium.onnx"
results="$HOME/piper-results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$results"
printf '%s\n' 'Your next meeting starts soon. Save your work and bring your notes.' > "$results/short.txt"
printf '%s\n' 'A local voice assistant turns written replies into speech on your computer. Once its voice files are downloaded, the speech engine does not need an internet connection. Short replies should begin quickly and sound clear. Longer explanations should remain natural, with comfortable pauses and consistent pronunciation. Listen for clipped words, odd emphasis, harsh consonants, and pauses that interrupt the meaning. Choose a voice that balances speed, clarity, and comfort throughout a busy day.' > "$results/long.txt"
for sample in short long; do
  for trial in 1 2 3; do
    unshare --user --map-root-user --net \
      time --format='elapsed_s=%e user_cpu_s=%U system_cpu_s=%S cpu_percent=%P peak_rss_kib=%M' \
      --output="$results/$sample-$trial.metrics" \
      piper --model "$voice" --length-scale 1.0 \
      --input-file "$results/$sample.txt" --output-file "$results/$sample-$trial.wav"
  done
done
```

The network namespace isolates only the test processes, not host networking or
NetBird. Stop if namespaces are unavailable; do not weaken host policy. Each CLI
call reloads the model. Later repetitions warm the **filesystem cache**, not a
resident model. These timings measure complete-file generation, **not** first
audio/playback latency. A resident-model/first-audio benchmark remains a separate
post-deployment test; command providers launch a new process per request. Listen
to the WAV files before changing the active provider, then test actual Hermes
CLI/Desktop playback. Offline TTS does not make GPT/Codex conversations local.

### Hermes Daily Assistant (`default`)

Use Hermes's supported command-provider interface to call the packaged executable
from both CLI and Desktop. Its built-in `piper` provider instead imports a Python
SDK into Hermes's interpreter, which this configuration deliberately does not
modify. Only after verified generation/listening and approval to change TTS, run
these **Bash** commands (no pip, uv, or runtime PM installation):

```bash
hermes -p default config set --force tts.providers.piper-local.type command
hermes -p default config set --force tts.providers.piper-local.command 'piper --model {model} --length-scale 1.0 --output-file {output_path} < {input_path}'
hermes -p default config set --force tts.providers.piper-local.model "${XDG_CACHE_HOME:-$HOME/.cache}/piper-voices/en_US-lessac-medium.onnx"
hermes -p default config set --force tts.providers.piper-local.output_format wav
hermes -p default config set --force tts.providers.piper-local.timeout 180
hermes -p default config set tts.provider piper-local
```

The provider is named `piper-local` to avoid shadowing Hermes's built-in provider.
The pinned CLI validator rejects these dynamically named provider paths without
`--force`, even though the TTS runtime reads them. Keep the `tts.providers` prefix;
the validator's suggested top-level `providers.piper-local` path is not the TTS
registry. `tts.provider` is a recognized key and does not need `--force`.
These commands change only TTS keys in `default`, not GPT models, Codex OAuth,
the sticky active profile or other profiles. Start a fresh default-profile
CLI/Desktop session after applying them. No rebuild is needed to change the
voice/model path. Preserve the previous TTS values for rollback rather than
overwriting the entire config.

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

**Already installed and booting? Do not run Disko formatting.** Do not erase/reinstall because a configuration switch or desktop service failed. Identify the failing stage (bootloader, LUKS unlock, Bcachefs mount, userspace, greetd, or Niri), collect the exact error/logs, and diagnose first.

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

Log in through tuigreet to Niri, then inspect:

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

The [laptop policy](../features/power/laptop-sleep.nix) requests suspend-then-hibernate on lid close on battery and AC; docked lid closure is ignored. Hibernation follows 60 minutes of suspension, including on AC. UPower's awake-state battery thresholds are low 20%, critical 12%, and Hibernate at 8%. The policy pulls `upower.service` into `multi-user.target` so battery protection starts at boot without a desktop client requesting D-Bus activation. These power settings are independent of the compositor.

The same profile supplies Swayidle, Swaylock and its PAM authentication service.
One `swayidle.service` is wanted by, ordered after and stopped with
`graphical-session.target`. Niri and Mango import the Wayland environment before
activating that target. `ConditionEnvironment=WAYLAND_DISPLAY` avoids starting
the listener outside a Wayland session. Logging out stops it; the next compositor
starts a new listener with its environment. This supports switching sessions,
not multiple concurrent graphical sessions for the same user.

The listener runs `swaylock -f` for both logind's `lock` and `before-sleep` events.
Swayidle's `-w` and Swaylock's `-f` wait for lock readiness before releasing the
sleep delay inhibitor, subject to logind's `InhibitDelayMaxSec` limit. No
inactivity timeout, automatic idle suspension, screen-power command or unlock
command is added. `-C /dev/null` prevents user Swayidle configurations from
silently adding conflicting events. Manual `swaylock` bindings still work.

After an approved deployment, use a fresh login and inspect these read-only
**Fish** diagnostics in each compositor:

```fish
systemctl --user is-active graphical-session.target swayidle.service
systemctl --user status swayidle.service --no-pager
systemctl --user show swayidle.service -p PartOf -p After -p MainPID
journalctl --user -b -u swayidle.service --no-pager
```

With separate authorization for disruptive runtime tests, lock the current
session with `loginctl lock-session`, authenticate, and repeat in the other
compositor. Before login, or after logout from a separate TTY, verify the listener
is inactive; after switching desktops confirm there is one listener with a new
PID and no missing-display/protocol errors. Then perform the approved sleep tests
below in both desktops, checking that the session is already locked on resume.
Include rapid compositor switching in the authorized logout/login tests because
Mango requests target shutdown and environment cleanup asynchronously.
Always verify the locker before relying on lid-close suspension in public.

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

Separately test short lid-close suspension on AC in both Niri and Mango: reopening should restore a **locked** session. Then test the full 60-minute transition, RTC wake, LUKS unlock, and session restoration. Historical manual hibernation success is not proof of this timed transition. Useful diagnostics:

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
