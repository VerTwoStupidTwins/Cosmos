# modules/timers/notes-inbox.nix
{
  # Nightly: the Notes vault's inbox filed, as its rules note promises. The owner's review mark on a transcription is
  # the approval (file_note and discard_note check it); notes still pending wait. Corrections are replies in the
  # post's thread.
  flake.modules.nixos.agent.agent.schedules.notes-inbox = {
    onCalendar = "*-*-* 02:00:00";
    roomName = "Notes";
    prompt = ''
      Nightly filing of the Notes vault's inbox. Call notes__list with folder "Inbox". If it holds no notes, answer
      NOTHING.

      Read "Reference/How this vault works" (the vault's rules) once. Then, for each inbox note, by its review property:
      - review: pending (or anything but accept or delete): leave it; the owner hasn't checked it yet.
      - review: delete: notes__discard_note.
      - review: accept, or no review property at all (a note saved from chat): file it. Read it, and find what it
        relates to with notes__search_by_meaning (and notes__list of Projects and Ideas). Then notes__file_note with:
        a clear name in the owner's own terms; the folder the rules give for it (an idea → Ideas, something with a
        finish line → its project's folder under Projects, or a new one, something to look up later → Reference);
        type and status; tags for ongoing topics, reusing tags the vault already has, and keeping "handwritten" on a
        transcription; and links to the two or three notes most related. Its open to-dos move to the tasks note on
        their own. A note mixing several things goes where its main point belongs. If you can't tell what a note is
        for, leave it and say so.

      Answer with one line per note: what it was, and where it went (or that it was deleted, or why it waits), then
      one line listing the to-dos that moved to Tasks. End with: reply in this thread to correct anything. Don't
      change anything else in the vault.

      When the owner replies with a correction, make it with notes__move and notes__edit (they approve each).
    '';
  };
}
