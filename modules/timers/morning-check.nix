# modules/timers/morning-check.nix
{
  # Every morning, but posted only when something needs the owner's attention: a quiet night leaves no message.
  flake.modules.nixos.agent.agent.schedules.morning-check = {
    onCalendar = "*-*-* 08:00:00";
    roomName = "Morning check";
    prompt = ''
      Morning check of the homelab. Look, read-only, at:
      - alerts that fired in the last 12 hours (observe__query: max_over_time(ALERTS{alertstate="firing"}[12h])) and
        alerts firing now (observe__alerts);
      - failed systemd units on any host (observe__query: node_systemd_unit_state{state="failed"} == 1);
      - filesystems more than 85% full, or on course to fill within a week
        (observe__query on node_filesystem_avail_bytes and node_filesystem_size_bytes, real filesystems only);
      - disks whose SMART health isn't passing (observe__query: smartctl_device_smart_status == 0);
      - open commitments in memory (memory__list with kind commitment and status open).

      If none of that needs attention, answer NOTHING.

      Otherwise give a short list, most important first: one line each, what it is, on which host, and what to
      check. Name the tool that told you. Alerts already explained in the Alerts room only need one line each.
      Don't change anything.
    '';
  };
}
