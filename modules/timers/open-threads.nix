# modules/timers/open-threads.nix
{
  # Sunday mornings: ideas, plans and commitments the owner left open or parked a month ago and hasn't come back to,
  # each shown at most once a month. Replies in the post's thread pick one up, park it again or drop it.
  flake.modules.nixos.agent.agent.schedules.open-threads = {
    onCalendar = "Sun *-*-* 10:00:00";
    roomName = "Open threads";
    prompt = ''
      Weekly open threads. Call memory__stale_threads. If it returns no threads, answer NOTHING.

      Otherwise write one line per thread, oldest first: "#id kind (status, untouched N days): what it is, and where
      the owner left it". Use memory__get or memory__recall when the item's own text doesn't say where it was left;
      don't invent context. Keep it short and plain, no pressure: the point is that nothing gets lost.

      End with one line: reply in this thread to pick one up, park it again, or drop it.

      When the owner replies, change the items with memory__update (status in_progress, parked or dropped, and any
      detail they add); each change is announced in the Memory room.
    '';
  };
}
