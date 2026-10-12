# Cosmos

Declarative NixOS configuration for the homelab, starting with `thoth`, a Lenovo ThinkPad T490. Cosmos uses Dendritic Nix modules via [flake-parts](https://github.com/hercules-ci/flake-parts) and [import-tree](https://github.com/denful/import-tree).

**Current status:** Thoth is installed and running NixOS 26.05 with Niri. The working configuration is maintained in `/Cosmos` and tracked in this repository. Only `thoth` is currently defined as a NixOS host.

## Thoth at a glance

| Area | Configuration |
| --- | --- |
| System | NixOS 26.05, `x86_64-linux`, Fish shell, user `twins` |
| Disk (currently installed) | GPT with 2 GiB FAT32 ESP and LUKS2-encrypted LVM: Bcachefs `nixos-root` and 32 GiB swap `nixos-swap` |
| Boot / storage (currently installed) | systemd-boot, systemd initrd, `/dev/mapper/cryptroot`, persistent swap and resume at `/dev/nixos/swap` |
| Desktop | SDDM (Wayland), Niri, PipeWire, Bluetooth, LXQt Polkit |
| Network | NetworkManager, firewall, OpenSSH, NetBird client `wt0` |
| Credentials | 1Password desktop and SSH agent |
| State | Persistent root; no ZFS, impermanence, or automatic root rollback |

Thoth has been reinstalled with LUKS2, LVM volume group `nixos`, Bcachefs `root` and a 32 GiB `swap` LV for hibernation (16 GiB RAM now, 24 GiB planned). A manual hibernate/resume test successfully restored Niri. **Never rerun destructive Disko formatting for routine rebuilds.** See [INSTALL.md](INSTALL.md) for installation and recovery precautions.

## Repository layout

- `flake.nix` and `flake.lock`: pinned inputs and flake entry point.
- `modules/hosts/thoth.nix`: host composition, user, hardware report, and boot settings.
- `modules/features/base.nix`: common Nix settings, locale, and base utilities.
- `modules/features/workstation.nix` and `cli-tools.nix`: NetworkManager and workstation/CLI packages.
- `modules/features/desktop/`: Niri, applications, and the LXQt Polkit systemd user service.
- `modules/features/security/onepassword.nix`: 1Password desktop and OpenSSH agent integration.
- `modules/features/netbird.nix`, `ssh.nix`, and `firewall.nix`: networking services.
- `modules/features/storage/bcachefs-root.nix`: root filesystem support.
- `modules/features/power/laptop-sleep.nix`: lid-driven suspend-then-hibernate, UPower critical-battery protection, and a Niri sleep-lock service.
- `hardware/thoth/facter.json`: the actual T490 hardware report used by NixOS Facter.
- `PACKAGES.md`: package and service inventory.

`flake.lock` and the Facter report are **already tracked** in the repository. Home Manager is declared as a flake input but is not yet activated. There are no custom Niri keybindings, themes, or Home Manager dotfiles in this repository.

## Network and SSH details

The NetBird client is named `wt0` and uses network interface `wt0` with configured UDP port `58120`. NetBird's NixOS service is enabled to autostart; configuration alone does not prove peer enrollment or connectivity.

OpenSSH is enabled with `openFirewall = true`. **SSH is not yet restricted to NetBird**. Verify NetBird access before tightening SSH firewall rules, to avoid losing remote access.

1Password supplies SSH identities through `~/.1password/agent.sock`. The NixOS OpenSSH client sets `IdentityAgent` system-wide, so `~/.ssh/config` is not required for that setting. The LXQt Polkit agent is declared as a systemd user service attached to `graphical-session.target`. The 1Password application must be running with its SSH agent enabled for the socket to accept connections.

## Working on Thoth

After merging changes on GitHub, update the local checkout:

```fish
cd /Cosmos
git status --short
git pull --ff-only

nix eval --raw '.#nixosConfigurations.thoth.config.system.build.toplevel.drvPath'
```

For a **non-storage Nix configuration change**, rebuild locally after reviewing the diff:

```fish
sudo nixos-rebuild switch --flake /Cosmos#thoth
```

Documentation-only updates do not require a rebuild.

Useful checks:

```fish
nix eval --raw '.#nixosConfigurations.thoth.config.services.netbird.clients.wt0.interface'
systemctl --user status lxqt-policykit-agent.service
ssh -G github.com | rg -i '^identityagent '
set -gx SSH_AUTH_SOCK "$HOME/.1password/agent.sock"
ssh-add -l
```

For installation from scratch or recovery, use [INSTALL.md](INSTALL.md), not the routine update commands above.

## Security note

This repository is **public**. The tracked Facter report can contain device identifiers or other machine metadata. Review it before publishing subsequent changes, and never commit passwords, SSH private keys, 1Password secrets, recovery keys, or LUKS key material.
