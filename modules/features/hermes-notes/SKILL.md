---
name: notes-ingest
description: The owner's private Notes vault at /var/lib/hermes/notes. Use it for the nightly notes-ingest job, which files the handwritten notes the owner accepted in Inbox/ into the vault (to-dos into Tasks.md, the rest into Notes/, linked to topic notes and tagged with feelings), and to answer from the owner's notes and to-dos.
version: 1.0.0
author: twins
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Notes, Obsidian, Tasks, Personal]
    related_skills: [obsidian]
---

# Personal notes

The Notes vault is the owner's private Obsidian vault, a folder of Markdown files at
`/var/lib/hermes/notes`. It syncs to the owner's devices within seconds, so everything you write is
what they read.

**It is private.** Never pass its contents to a subagent (`delegate_task`), never copy them into the
research wiki, and never send them anywhere except your own reply to the owner. Do the work yourself.

Use file tools with absolute paths: `read_file`, `write_file`, `patch` and `search_files`. You never
need the terminal here, and you never delete files: the transcriber service does that (see step 6).

## Layout

```
/var/lib/hermes/notes/
  Inbox/          transcriptions of the owner's handwriting, waiting for review: one note per drawing
  Notes/          filed notes, one per inbox note: "<YYYY-MM-DD> <Title>.md"
  Topics/         one hub note per topic, concept, project, person or interest: "<Name>.md"
  Tasks.md        every to-do, newest last
  Excalidraw/     the drawings themselves: never edit
  .obsidian/      Obsidian's settings: never touch
```

Create a folder or `Tasks.md` the first time you need it.

## Inbox notes

The transcriber service writes an inbox note for each handwritten drawing:

```
---
source: "[[Excalidraw/Drawing 2026-11-18 15.17.25.excalidraw]]"
tags: [handwritten]
transcribed: 2026-11-18 16:17
transcription: current
review: pending
png-sha256: …
text-sha256: …
---
- [ ] Clean room
- [ ] fix Server
This is a test

![[Excalidraw/Drawing 2026-11-18 15.17.25.excalidraw]]
```

During the day the owner reads these, corrects the transcriptions, and sets each note's `review` to
`accept` or `delete`. Every night at midnight the notes-ingest job runs: its script first deletes
the notes marked `delete` (with their drawings), then lists the accepted notes in your prompt. Ingest
exactly those. Never touch an inbox note that is `pending`, and never ingest one marked `delete`.

## Ingesting an accepted note

The owner has corrected the text, so the words are right: don't fix spelling, reword, summarise or
leave anything out. You may add structure (headings, paragraphs, lists) and links.

For each accepted inbox note:

1. **Read it**, and read the list of existing topics (`Topics/`) so you reuse them.

2. **To-dos.** Every `- [ ]` or `- [x]` line goes to `Tasks.md`, appended at the end, in the owner's
   words, with the date it was written and a link to the filed note (or no link if the note was only
   to-dos):

   ```
   - [ ] Clean room ➕ 2026-11-18 [[Notes/2026-11-18 Weekend plans]]
   ```

   Keep any due date the owner wrote, as `📅 YYYY-MM-DD`. Leave out a to-do that is already open in
   `Tasks.md` with the same words. If `Tasks.md` is new, start it with `# Tasks` and a blank line.

3. **The filed note.** If anything is left besides the to-dos, write it to
   `Notes/<date> <Title>.md`, where the date is the inbox note's `transcribed` date and the Title is
   a few words naming what it's about. Don't overwrite an existing note: add " 2", " 3".

   ```
   ---
   created: 2026-11-18
   tags: [handwritten, feeling/stressed]
   topics: ["[[Homelab]]", "[[Family]]"]
   ---
   The owner's text, structured, with [[Topic]] links where a topic is mentioned.

   To-dos from this note are in [[Tasks]].
   ```

   Leave out the drawing embed and the transcriber's fields: the drawing is deleted afterwards.

4. **Topics.** Link the note to 1–4 topics: the projects, people, places, interests and ideas it is
   about. Reuse an existing topic whenever one fits; make a new one only for something likely to
   come up again. A topic note is `Topics/<Name>.md`, named in Title Case:

   ```
   # Homelab

   One line on what this topic is, from what the owner has written.

   ## Notes
   - [[Notes/2026-11-18 Fix the server]]: one line on what that note says about this topic
   ```

   Append a line to `## Notes` in each topic note you link.

5. **Feelings.** If the owner expresses how they feel, add a tag for each feeling:
   `feeling/<word>`, one lowercase word (stressed, excited, tired, grateful, anxious, proud…), reusing
   words already used in the vault. Only feelings the owner actually expresses: a neutral note gets
   none.

6. **Hand it back.** Only when the filed note, `Tasks.md` and the topic notes are written, change the
   inbox note's `review: accept` line to `review: filed` (with `patch`). The transcriber service then
   deletes the inbox note and its drawing. Don't change anything else in the inbox note, and if you
   couldn't finish a note, leave it `accept` so tomorrow's run tries again.

## Replying

Reply with one short line per note you filed, like
`Filed "Weekend plans": 2 to-dos, topics Homelab and Family, feeling stressed.`, then a line with how
many notes the script deleted, if any. When nothing was deleted or accepted, reply with exactly
`[SILENT]`.

## Answering from the notes

When the owner asks about their own plans, to-dos, ideas or how they've been, search the vault
(`search_files` in `/var/lib/hermes/notes`): open to-dos are the `- [ ]` lines in `Tasks.md`, and
`Topics/` and the `feeling/` tags lead to related notes. Mention which note you're drawing on.
