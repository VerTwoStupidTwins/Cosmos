# T490 lid-close power management

Thoth uses a declarative laptop policy in `modules/features/power/laptop-sleep.nix`.

- Closing the lid, on battery or AC: systemd-logind requests `suspend-then-hibernate`.
- While docked with external displays: logind ignores lid closure.
- `systemd-sleep` hibernates after 60 minutes suspended, including on AC.
- UPower monitors battery charge while the laptop is awake: low 20%, critical 12%, action at 8%. At the action threshold UPower requests `Hibernate`.
- The `swayidle` user service starts with `niri.service`, and runs `swaylock -f` before a system sleep transition to lock the graphical session.
- `nixos-swap` is the persistent 32 GiB LVM swap device, already verified for manual hibernation.

Niri session locking depends on `swayidle.service` starting in the user session. Always verify that service before relying on lid-close suspension in public.

## Evaluate before changing the running system

```fish
cd /Cosmos
git status --short
nix eval --raw '.#nixosConfigurations.thoth.config.services.logind.settings.Login.HandleLidSwitch'
nix eval --raw '.#nixosConfigurations.thoth.config.systemd.sleep.settings.Sleep.HibernateDelaySec'
nix eval --json '.#nixosConfigurations.thoth.config.services.upower.enable'
nix eval --raw '.#nixosConfigurations.thoth.config.services.upower.criticalPowerAction'
nix eval --raw '.#nixosConfigurations.thoth.config.boot.resumeDevice'
```

Run the normal NixOS rebuild only after examining the branch diff and CI results. **Reboot after applying**: NixOS deliberately avoids restarting `systemd-logind` mid-session, so changing the configuration alone may leave the old lid policy active until reboot.

## Verify after reboot

```fish
systemd-analyze cat-config systemd/logind.conf
systemd-analyze cat-config systemd/sleep.conf
systemctl --user status swayidle.service
systemctl status upower.service
upower -e
swapon --show
```

Use `upower -i <battery-object-path>` for battery information, substituting an object path printed by `upower -e`. Do not deliberately drain the battery to 8% just to test the action threshold.

First test lid close with open work saved and the laptop on AC: reopening the lid after a few seconds should restore a **locked** Niri session. Next test the full 60-minute suspend-to-hibernate transition, including the RTC wake and restoration after entering the LUKS passphrase. `journalctl -b -u systemd-suspend-then-hibernate.service --no-pager` and `journalctl -b -k --no-pager | grep -Ei 'hibernat|resume'` can help diagnose problems.

The existing manual `systemctl hibernate` test does **not** prove that the timed transition works. Keep the policy under review until both tests pass.
