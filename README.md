# Cosmos

Declarative NixOS homelab configuration using [flake-parts](https://github.com/hercules-ci/flake-parts) and [import-tree](https://github.com/denful/import-tree) in the Dendritic module style.

## Flake structure

```text
flake.nix                       Inputs and flake-parts entry point
flake.lock                      Tracked, pinned dependency graph
modules/
  development.nix               Development shell, formatter, pinned Disko app
  features/                     Contributions to reusable NixOS profiles
    desktop/                    Shared desktop, Niri, Mango, tuigreet, applications
    power/                      Laptop sleep and locking policy
    security/                   1Password integration
    storage/                    Bcachefs support
  hosts/
    thoth.nix                   Host composition and nixosConfigurations.thoth
    thoth.md                    Thoth operations, installation, and recovery
hardware/thoth/facter.json       Tracked machine-specific hardware report
disk-layouts/thoth.nix           Machine-specific Disko layout
.github/workflows/
  nix-validation.yml            Evaluation, regression checks, and style checks
AGENTS.md                       Contributor and agent working rules
```

`flake.nix` enables flake-parts' module registry and recursively imports the Nix files under `modules/`. These files are **flake-parts modules**, not directly imported NixOS configuration files. They contribute named modules under `flake.modules.nixos`.

Multiple feature files can extend the same profile:

| Profile | Contributions |
| --- | --- |
| `base` | Nix settings, locale, CLI tools, firewall, OpenSSH, resolved, NetBird |
| `workstation` | NetworkManager, terminals, 1Password |
| `base-desktop` | Shared graphics/audio, Bluetooth, dconf, GNOME Keyring, applications, fonts and session-bound Polkit agent |
| `niri-desktop` | Niri session/portals and XWayland Satellite only |
| `mango-desktop` | nixpkgs Mango session/portals, session target and minimal fallback bindings; experimental on Thoth |
| `tuigreet-login` | greetd/tuigreet on VT1, installed-session chooser and per-user session memory |
| `bcachefs-root` | Bcachefs support, systemd initrd, disabled zram swap |
| `laptop-sleep` | Lid handling, timed hibernation, UPower, shared Wayland sleep/logind locking |
| `local-tts` | nixpkgs Piper CPU speech CLI and timing tools; Hermes packages remain unchanged |

Host modules compose these profiles with machine-specific settings and expose `flake.nixosConfigurations.<host>` through `nixpkgs.lib.nixosSystem`. Disk layouts outside `modules/` are imported explicitly. Host Markdown files are documentation, not imported Nix modules.

Compose `base-desktop` with the chosen compositor profile(s) and login profile at the host level. Shared desktop features do not enable a compositor or start Mango-specific applications; changing window managers does not require moving the shared application/service declarations.

## Inputs and outputs

- Supported flake system: `x86_64-linux`.
- Root `nixpkgs`: `nixos-unstable`, pinned in `flake.lock`.
- Disko and the root Home Manager input follow the root `nixpkgs`.
- The root Home Manager input tracks upstream's default branch; it remains inactive.
- Mango uses the root nixpkgs package/module, without an additional upstream flake input.
- Hermes supplies upstream CLI/Desktop packages and retains its own pinned dependency graph, including a separate nixpkgs input. Do not assume every package uses the root nixpkgs revision.
- Home Manager is declared but is **not activated** by Cosmos.
- Outputs include `nixosConfigurations.thoth`, the default development shell, the Nixfmt formatter, and the pinned `disko` app.

The only defined host is [Thoth](modules/hosts/thoth.md), a ThinkPad T490. Its composition is in [thoth.nix](modules/hosts/thoth.nix). When adding hosts, audit shared-profile assumptions: `base` enables SSH/NetBird and the 1Password workstation policy currently names `twins`.

## Contributing and validation

Follow [AGENTS.md](AGENTS.md) for branch, approval, and validation requirements. Never make changes directly on `main`. Use focused topic branches from freshly fetched `origin/main` and review diffs before committing.

[GitHub Actions](.github/workflows/nix-validation.yml) runs for pull requests, pushes to `main`, and manual dispatch. It discovers all NixOS hosts, evaluates their derivations, checks flake outputs, verifies Thoth's resume/power/NetBird settings, and enforces Statix, Deadnix, and Nixfmt. CI is not a full system build, boot test, or deployment.

Use the pinned tools with `nix develop`. Nix evaluation and development-shell commands can download dependencies and write to the Nix store; they are not strictly read-only. Documentation-only changes need documentation checks, not a NixOS rebuild.

## Documentation and security

Keep repository structure here, contributor rules in `AGENTS.md`, and machine-specific operational guidance next to each host module as `modules/hosts/<host>.md`. Package declarations in the Nix modules are the authoritative inventory; avoid duplicating a full package manifest in Markdown.

This repository is public. Never commit credentials, SSH private keys, recovery secrets, or LUKS key material. Review hardware reports for identifiers before publishing changes.
