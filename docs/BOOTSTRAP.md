# Cosmos: commissioning a new NixOS host

**Scope:** The new `/Cosmos` flake-parts/import-tree repository on Thoth, not
any older Cosmos repository. This document and `scripts/bootstrap-host` are a
starter for repeatable installation, not a command to install a system.

## Access-first principles

1. A first-boot host must have working wired LAN networking, OpenSSH, and the
   `twins` account with *already authorized* public SSH keys.
2. SSH password and keyboard-interactive authentication remain disabled. Root
   SSH remains disabled **on the installed OS**. The live installer is separate.
3. `secrets/shared.yaml` holds `twins-password-hash`; its SOPS secret uses
   `neededForUsers = true` and the user uses `hashedPasswordFile`. Keep this
   file limited to secrets intentionally shared by every managed host; put
   host-specific credentials in separate host files.
4. Each host has a **unique** SSH host Ed25519 key. Its public key determines
   an age recipient; its *private* key is transferred before activation, never
   through Git or the Nix store.
5. `users.mutableUsers = true` is retained for first-install behavior. New
   accounts take the secret hash. Existing account passwords are not forcibly
   replaced at rebuild time. A fleet-wide password rotation is a separate
   policy change and requires its own plan.
6. NetBird starts with the shared base but enrollment is *manual* after LAN
   and SSH have worked. Never make NetBird enrollment a prerequisite for first
   admin login.
7. The install uses Disko only on a **reviewed disk**. A successful Nix
   evaluation/build is not proof of correct disk selection or network access.
8. Installation **does not automatically reboot**. Require independent checks
   and a human decision before first reboot.

## Layout

```text
/Cosmos/
  modules/system/base.nix
  modules/system/ssh-server.nix
  modules/users/twins/account.nix
  modules/hosts/<host>.nix
  hosts/<host>/disko.nix
  hosts/<host>/facter.json
  keys/ssh/hosts/<host>.pub             # Public host identity ONLY
  .sops.yaml
  secrets/shared.yaml                  # SOPS ciphertext
  secrets/<host>.yaml                  # Optional host-specific ciphertext
  scripts/bootstrap-host               # This non-destructive helper
  docs/BOOTSTRAP.md
```

Keep the existing flake module registry, `flake.nixosModules` profiles,
`modules/core.nix`, home-manager and Thoth composition. **Do not replace** those
with the structure above: this is only a placement guide.

## Stage A: Verify existing shared modules on Thoth

Preconditions in the evaluated configuration:

```nix
# Existing shared user NixOS module (illustrative additions only):
sops.secrets."twins-password-hash" = {
  sopsFile = ../../../secrets/shared.yaml;
  neededForUsers = true;
};
users.users.twins.hashedPasswordFile =
  config.sops.secrets."twins-password-hash".path;

# SOPS should use the matching, persistent SSH host decryption key:
sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
```

These options belong *inside the appropriate existing NixOS module*, not at
top level in a flake-parts module. Leave working existing imports alone.

Also ensure `services.openssh.settings.PasswordAuthentication = false`,
`KbdInteractiveAuthentication = false`, `PermitRootLogin = "no"`,
`services.openssh.openFirewall = true` for first-boot LAN recovery,
`users.users.twins.openssh.authorizedKeys.keys` includes a key accessible from
Thoth or another commissioning client, and `users.users.twins.extraGroups`
includes `wheel`.

```bash
cd /Cosmos
bash scripts/bootstrap-host preflight thoth
```

The preflight evaluates the flake (which may access the Nix store); it does
not build a host closure, switch, reboot, format or decrypt secrets. It checks **configuration declarations**, not whether a
running system has actually accepted connections. If any check fails, correct
only that existing module and re-run before proceeding.

## Stage B: Register the new host

Create the new host composition using your existing `flake.nixosModules` module
selection and host patterns. It should import shared `base`, the shared `twins`
user, and SOPS; supply its real Facter report and a reviewed host-specific
Disko layout. Set `networking.hostName`. Configure reliable **first-boot LAN**
networking explicitly: DHCP on wired Ethernet is the usual starting point for
headless hosts. A live installer having networking does **not** guarantee the
installed system has networking.

Before installing, identify the target physically and confirm its `/dev/disk/by-id`
path and storage capacity. Never substitute a different host's Facter report.

```bash
bash scripts/bootstrap-host preflight <host>
nix build --no-write-lock-file --no-link '.#nixosConfigurations.<host>.config.system.build.toplevel'
```

Replace `<host>` everywhere with the actual new hostname. Use a matching
flake expression; don't literally include brackets. If you created new
Git-untracked Nix or Facter files, stage those files for normal `.#host` flake
evaluation (`git add <specific-paths>`); stage is not a commit. Review the
staged diff before proceeding. Review Disko's output and the target's disk IDs **before** authorizing a destructive operation.

## Stage C: Prepare a new, private host identity

On Thoth, generate an Ed25519 **SSH host key**, not an SSH user key. It is
staged in a private runtime directory (normally `/run/user/<uid>`), not the
repository. The script refuses to generate an identity if the repository
already contains `keys/ssh/hosts/<host>.pub`.

```bash
# ssh-to-age is needed for this step; use your pinned development shell or:
nix shell --inputs-from . nixpkgs#ssh-to-age --command \
  bash scripts/bootstrap-host prepare-identity <host>
```

Note the staging directory printed by the helper. Example:

```bash
STAGE=/run/user/1000/cosmos-newhost-bootstrap.XXXXXXXX
```

This path is an illustration: **use the exact path printed** by the command,
not the literal example. Keep its private key out of shell command output,
repo, cloud sync, logs and chat. Store an encrypted backup via your secure
credential/backup workflow if the key must survive installer failure.

Record the public key in the repository:

```bash
install -Dm644 "$STAGE/extra-files/etc/ssh/ssh_host_ed25519_key.pub" \
  "keys/ssh/hosts/<host>.pub"
```

Also save the host fingerprint from the staging directory so you can compare
it after installation. The public key and fingerprint are not secrets.

## Stage D: Authorize the new host in SOPS

Add the **public age recipient** printed by `prepare-identity` to the existing
`secrets/shared.yaml` creation rule in `.sops.yaml`. Preserve the existing
Thoth, recovery and all other host recipients; don't touch `thoth.yaml`
recipients unnecessarily.

Example fragment (merge into the existing structure; don't paste placeholders):

```yaml
# .sops.yaml: existing creation_rules entry for shared.yaml
- path_regex: ^secrets/shared\.yaml$
  key_groups:
    - age:
        - *thoth
        - *recovery
        - age1PUBLIC_RECIPIENT_FOR_NEW_HOST
```

Then update actual encrypted file metadata:

```bash
sops updatekeys secrets/shared.yaml
bash scripts/bootstrap-host verify-decryption "$STAGE"
```

**Important:** Editing `.sops.yaml` *alone* is not enough; `sops updatekeys`
re-encrypts the data-key access for the new recipient. The decryption test
isolates itself from Thoth's SOPS operator/recovery keys, so an accidental
success with Thoth's key cannot mask a missing recipient.

No password hash or plaintext secret should be printed by these commands.

## Stage E: Install with a deliberate stop before reboot

1. Boot the **target**, not Thoth, into a suitable NixOS installer. Prefer a
   wired LAN connection. Ensure Thoth can SSH into the live installer and
   verify the SSH host fingerprint/physical target. One way to enable temporary
   installer access from its physical console is to set an installer-only root
   password using `sudo passwd root` and start SSH using
   `sudo systemctl start sshd`; alternatively add Thoth's public SSH key to
   the installer's root `authorized_keys`. The temporary installer is not the
   installed OS, whose root SSH and password authentication stay disabled.
2. Inspect `lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE`, firmware UEFI mode, and the
   `/dev/disk/by-id` entries on the target. Compare them against Disko. Inspect
   the formatted-device plan. Keep backup/recovery media ready.
3. Ensure the target's actual CPU, firmware and network hardware are accounted
   for; evaluate/build the host closure on Thoth or a designated build machine.
4. After separate, explicit authorization to erase **that specific disk**, use
   your pinned `nixos-anywhere` binary/app with these *arguments* (exact app
   invocation depends on the inputs/outputs in your local flake):

```bash
# DESTRUCTIVE TEMPLATE: DO NOT RUN until the target, disk, and access preflight
# have been independently verified and you approve this specific installation.
# When the target is already on a NixOS installer, omit the kexec phase.
# Replace <host>, <target-ip>, and $STAGE with real verified values.
nixos-anywhere \
  --flake "path:$PWD#<host>" \
  --target-host 'root@<target-ip>' \
  --extra-files "$STAGE/extra-files" \
  --phases disko,install
```

`--phases disko,install` deliberately omits `reboot`; **`disko` is still
fully destructive**. Do not use it for upgrades or to repair an existing
filesystem. `--extra-files` copies the private SSH host key into the installed
root before NixOS activation. Use your locked/pinned `nixos-anywhere` tool for
reproducibility; if none is present, pin one deliberately rather than assuming
some older repository provides it.

## Stage F: Check the installed system before first reboot

From the live installer session on the target:

```bash
findmnt /mnt
findmnt /mnt/boot
stat -c '%U:%G %a %n' /mnt/etc/ssh/ssh_host_ed25519_key
ssh-keygen -lf /mnt/etc/ssh/ssh_host_ed25519_key.pub
ls /mnt/boot/EFI  # inspect the actual bootloader layout for this host
```

Check the target's host fingerprint against the one generated on Thoth.
Review `/mnt/etc/ssh`, relevant `/mnt/run`/activation logs and any installer
errors. Do not reboot if the host private key was not copied, `sops-nix`
could not provision secrets, user creation failed, or boot entries are missing.
NixOS `nixos-install`/`nixos-anywhere` can have version-dependent activation
behavior; trust the actual logs and mounted filesystem, not assumptions.

## Stage G: First boot, LAN SSH, then manual NetBird enrollment

Only after the check and separate reboot approval, boot the installed system.
Verify the server's offered host SSH fingerprint against the saved key; never
use `StrictHostKeyChecking=no` as a shortcut.

```bash
ssh twins@<lan-ip>
hostname
sudo -k
sudo -v
sudo test -s /run/secrets-for-users/twins-password-hash
sudo stat -c '%U:%G %a %n' /run/secrets-for-users/twins-password-hash
sudo sshd -T | grep -E '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication) '
```

Enter the shared password only at the `sudo` prompt, not in the shell command.
Test a second SSH session before ending the first.

Then perform the **manual** NetBird enrollment (no setup key in SOPS):

```bash
sudo netbird-wt0 up --no-browser
sudo netbird-wt0 status
ip -br addr show wt0
```

Verify remote SSH from a NetBird peer, ideally the phone over cellular data.
Keep first-boot LAN SSH available until the VPN and recovery plan work; only
then separately consider restricting SSH firewall access.

## Non-negotiable stop conditions

- Preflight fails, or the commissioning client has no matching private SSH key.
- Network boot plan is missing (especially Wi-Fi-only hosts).
- Target SSH fingerprint or disk identification is unexpected.
- `verify-decryption` fails with the staged host key alone.
- Disko target differs from the physically inspected disk.
- Installed SSH host key, account, SOPS secret or bootloader cannot be verified.
- No local console/out-of-band recovery exists on a host whose boot state is
  still unproven.

The first version of `scripts/bootstrap-host` intentionally does **not**
automate these dangerous transitions. Once we have tested the process on a
noncritical machine, add more operations with explicit confirmations and
separate dry-run/execute modes. Don't treat a successful build as a successful
installation or remote connectivity test.
