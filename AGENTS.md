# Working in Cosmos

These rules apply to the entire repository. Read [README.md](README.md) for the flake structure and the relevant host guide ([Thoth](modules/hosts/thoth.md), [Argus](modules/hosts/argus.md), or [Odin](modules/hosts/odin.md)) before host-specific work.

## Non-negotiable rules

- Never modify or commit directly on `main`.
- Never run `nixos-rebuild switch` without explicit user permission. Permission to edit, validate, or commit is not deployment permission.
- Never modify `flake.lock` unless the task requires a dependency/lock change. Do not update inputs incidentally to fix unrelated errors.
- Validate changes before proposing a commit.
- Show the user the complete Git diff, including new files, before committing; wait for approval to commit.
- Ask permission before pushing or opening a PR. Do not infer either permission from approval to commit.
- Before removing any document, explain the consolidation/removal and wait for approval. Preserve necessary procedures and repair links when removal is approved.
- Do not format disks, install NixOS, regenerate hardware reports, reboot, suspend, hibernate, change credentials, or manipulate running services without explicit authorization for that action.

## Git workflow

At the start of a task, inspect `git status --porcelain=v1 --untracked-files=all`. If there are uncommitted changes, stop and ask how to proceed. Do not stash, reset, clean, overwrite, or include someone else's work automatically.

For new work, fetch the remote, confirm the tree is still clean, then branch directly from the freshly fetched main reference. Use the requested branch name; otherwise use a focused `feature/`, `fix/`, `docs/`, or `ci/` branch.

```bash
git fetch origin
git switch --no-track -c feature/describe-the-change origin/main
```

Do not reuse an existing branch or rewrite history without checking with the user. Keep changes focused. Stage only intended files after diff review, use a descriptive conventional commit message, and keep push/PR approval separate. Do not claim CI has passed or a PR has merged without checking the remote state.

## Architecture and NixOS conventions

- `flake.nix` uses flake-parts and import-tree to load Nix files under `modules/` automatically.
- Feature files contribute to `flake.modules.nixos.<profile>`; several files can extend one profile. Do not treat these files as ordinary NixOS modules imported directly by a host.
- Put reusable features in `modules/features/`; put host composition, user/hardware choices, and `nixosConfigurations.<host>` in `modules/hosts/<host>.nix`.
- Keep host operations in `modules/hosts/<host>.md`, next to the host module. Keep root README content focused on repository/flake structure; do not create redundant host guides or package inventories.
- Keep machine-specific Disko layouts in `disk-layouts/<host>.nix` and real Facter reports in `hardware/<host>/facter.json`.
- Hosts `thoth`, `argus`, and `odin` use `x86_64-linux` and pinned `nixos-unstable`, with `system.stateVersion = "26.05"`. Argus is a headless Dell NVR with native Frigate; its real Facter report, disk IDs, and admin public key are declared, while cameras remain pending. Odin is a headless Ryzen server foundation with a real Facter report, one identified NVMe, and three unencrypted ESP/swap/Bcachefs partitions. Its model-tools profile supplies the native Hugging Face CLI; reusable llama-cpp-instances declares separate Intel B50 SYCL and Radeon 7900 XT Vulkan servers with per-instance packages, device selection, and CLI names. Both standalone instances remain disabled; Odin's native llama-swap profile instead owns the on-demand Vulkan children and provisions the explicitly selected testing artifacts outside home before the proxy starts. Configuration is not proof of activation or runtime validation. Never substitute another machine's report. Thoth is the workstation. Home Manager is an input, not an activated configuration. greetd/tuigreet discovers installed sessions and remembers each user's selection, without a forced compositor command. `laptop-sleep` declares shared Wayland locking for Niri and Mango; deployment and runtime lock/resume tests remain separate requirements.
- Preserve `system.stateVersion` unless a deliberate migration requires changing it; it is not a package-release selector.
- Prefer focused declarative contributions and normal module merging. Do not introduce `mkForce`, global unfree enablement, overlays, or imperative workarounds without explaining the need.
- Audit shared assumptions when adding hosts: the base profile enables OpenSSH and NetBird `wt0`, and the 1Password policy names `twins`.
- Installed packages, enabled services, and session-started applications are different. Verify each claim at the appropriate layer.

## Validation requirements

Run commands from the repository root. For interactive Cosmos work, use Odin for Nix evaluation, validation, and compilation; Thoth is the editing/staging client, not the build host. Run the commands over strict SSH from Odin's matching `/Cosmos` checkout instead of starting local laptop builds or `nix develop` jobs, unless the user explicitly requests otherwise. This does not authorize activation: switching still happens separately on the target host. CI continues to use its declared runners.

Distinguish checks actually run from checks only documented or deferred. Do not silently skip failed checks or change the lock file to make them pass.

### Documentation-only changes

- Run `git diff --check` and check new files for whitespace errors too.
- Check local links/anchors, referenced paths, code fences, and shell-example syntax.
- Compare operational statements and expected values with the current Nix modules and CI workflow.
- Verify no Nix source, hardware report, or `flake.lock` changed.
- Include new files in the diff shown to the user; plain `git diff` omits untracked files.
- No NixOS evaluation, build, or rebuild is required solely for Markdown edits.

### Nix configuration changes

Use pinned tools from `modules/development.nix`. Evaluate **all configured hosts**, including future hosts, before checking the flake. The current CI order works around Hermes/uv2nix filtered-source handling on clean stores; preserve that order until the pinned upstream implementation no longer needs it.

Discover host names with:

```bash
nix eval --no-write-lock-file --json --apply builtins.attrNames '.#nixosConfigurations'
```

Evaluate each discovered host's `config.system.build.toplevel.drvPath`; for Thoth:

```bash
nix eval --no-write-lock-file --raw '.#nixosConfigurations.thoth.config.system.build.toplevel.drvPath'
nix flake check --no-write-lock-file --no-build --show-trace
nix develop --no-write-lock-file --command statix check .
nix develop --no-write-lock-file --command deadnix --fail .
```

Check formatting with the pinned Nixfmt. Formatting tools may rewrite files: review resulting changes and do not copy CI's in-place formatting step into a read-only exploration. CI formats tracked Nix files in its disposable checkout and fails on the diff.

Retain the regression checks in `.github/workflows/nix-validation.yml`: Thoth resume and swap must match `/dev/nixos/swap`; lid policy is `suspend-then-hibernate`; delay is `60min`; UPower is enabled with `Hibernate` at 8%; NetBird interface is `wt0`; Niri and Mango are enabled/registered; the shared Wayland locker follows `graphical-session.target`, checks `WAYLAND_DISPLAY`, and handles logind lock/before-sleep events; greetd has a nonempty tuigreet command with generated session directories, per-user session memory, no `--cmd`/forced desktop environment, text-greeter mode and no autologin, while SDDM is disabled.

Evaluation is not a successful build; a build is not a boot, network-connectivity, screen-lock, or resume test. Perform additional build/runtime checks only within the authorized scope. Nix commands may download inputs and write to the Nix store even with `--no-build`; do not run them for strictly read-only requests. For Git inspections, use `GIT_OPTIONAL_LOCKS=0` where appropriate.

## Deployment and host safety

Routine deployment is manual and local; there is no declared deploy-rs, Colmena, remote deployment wrapper, or deployment CI. The pinned `nixos-anywhere` app is for separately approved fresh installation, not routine deployment. Argus's remote-install procedure omits automatic reboot so its sudo/console password can be set interactively. Follow the host guide only after explicit approval for the relevant operations.

Thoth uses persistent Bcachefs root and 32 GiB swap inside LUKS-encrypted LVM, systemd-boot, and a systemd initrd. Never use Disko formatting to apply routine updates. Storage, encryption, boot, and resume changes require dedicated review and verification against the actual installed layout, not assumptions from documentation.

Do not substitute another machine's Facter report. Regenerate it only on the named host for an authorized hardware-report task, review the diff and identifiers, and restore ownership if necessary. Use the repository-pinned Disko app for any authorized installation.

## Security and reporting

This is a public repository. Never add passwords, private keys, API credentials, recovery codes, 1Password secrets, or LUKS key material. Do not print secrets while diagnosing authentication failures.

SSH currently opens its firewall port broadly; it is not NetBird-only. Verify NetBird enrollment and access before proposing tighter SSH exposure. The 1Password SSH agent needs the GUI running with the agent enabled at `~/.1password/agent.sock`.

Use Bash examples for installer/CI procedures and label Fish-specific workstation examples. Finish with a short report of changes, checks and their real results, and remaining approvals. Never report evaluation, deployment, or runtime success based only on configuration or inherited documentation.
