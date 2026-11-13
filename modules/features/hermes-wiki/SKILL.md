---
name: llm-wiki
description: The owner's research wiki at /var/lib/hermes/wiki, an Open Knowledge Format (OKF) bundle synced to Obsidian. Use it to file every finished research report, to answer questions from what's already known, and to lint it when asked.
version: 1.0.0
author: twins
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Wiki, Research, Obsidian, OKF, Knowledge]
    related_skills: [obsidian]
---

# Research wiki

The wiki is a folder of Markdown files at `/var/lib/hermes/wiki`. It follows the LLM-wiki pattern: raw
research is kept unchanged, and you maintain summary pages that link to each other and cite it. The
format is Open Knowledge Format (OKF) v0.2. The folder syncs to the owner's Obsidian within seconds,
so everything you write is what they read.

Use file tools with absolute paths: `read_file`, `write_file`, `patch` and `search_files`.

## Layout

```
/var/lib/hermes/wiki/
  index.md                  every page, grouped by section, one line each
  log.md                    dated history of changes, newest first
  topics/<slug>.md          summary pages you write and keep current
  references/<date>-<slug>.md   research reports saved as they arrived, never edited afterwards
  .obsidian/                Obsidian's settings: never touch
  memory/                   generated from Hermes' memory database: never edit, and leave it out of index.md
```

Slugs are lowercase words joined by hyphens, like `arc-vulkan-llama-cpp`. Add more folders under
`topics/` only when a section grows past about 15 pages.

If `index.md` or `log.md` is missing, create it as shown below.

## Page format

Every `.md` file except `index.md` and `log.md` starts with YAML frontmatter, and `type` is required.

Topic page:

```markdown
---
type: Topic
title: Intel Arc Vulkan support in llama.cpp
description: One sentence saying what this page covers.
tags: [gpu, llama-cpp]
status: stable
generated: { by: hermes/main, at: 2026-11-12T18:00:00Z }
stale_after: 2027-05-12T00:00:00Z
sources:
  - id: research-2026-11-12-arc-vulkan
    resource: /references/2026-11-12-arc-vulkan.md
    title: Claude research report
  - id: llamacpp-vulkan-docs
    resource: https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md
    title: llama.cpp build docs
---

# Intel Arc Vulkan support in llama.cpp

Short summary first, then sections. Every factual claim cites a source by its id.[^llamacpp-vulkan-docs]

Related: [B580 benchmarks](/topics/b580-benchmarks.md)

[^llamacpp-vulkan-docs]: llama.cpp build docs
```

Reference page:

```markdown
---
type: Research Report
title: Arc Vulkan support in llama.cpp
description: The question that was researched, in one sentence.
status: stable
generated: { by: claude/sonnet, at: 2026-11-12T17:55:00Z }
sources:
  - id: src-1
    resource: https://example.com/page
---

The report exactly as the research subagent returned it.
```

Rules:

- `generated.by` names the model that wrote the content: `claude/sonnet` or `claude/opus` for research
  routes, `hermes/main` for pages you write. Timestamps are ISO 8601 UTC with a `Z`.
- `stale_after` goes on pages about fast-moving subjects such as AI news, releases or prices, usually
  3 to 6 months after `generated.at`. Leave it off for stable knowledge.
- Link pages with standard Markdown links from the wiki root, like `[B580 benchmarks](/topics/b580-benchmarks.md)`.
  Never use `[[wikilinks]]`. A link to a page that doesn't exist yet is fine and marks a gap.
- Cite claims with footnotes whose label is a `sources` id. Keep ids stable when you edit a page.
- Never add or change `verified`. Only the owner adds it, as `verified: { by: human:twins, at: ... }`,
  after reviewing a page. When you substantially rewrite a verified page, keep its `verified` entry and
  say in the log that the page changed since it was verified.
- Mark outdated pages `status: deprecated` rather than deleting them, and link to what replaces them.

## index.md

No frontmatter, except `okf_version` at the top:

```markdown
---
okf_version: "0.2"
---

# Hardware

* [Intel Arc Vulkan support in llama.cpp](/topics/arc-vulkan-llama-cpp.md) - one-line description

# References

* [2026-11-12 Arc Vulkan support](/references/2026-11-12-arc-vulkan.md) - one-line description
```

Group topics under sections you choose. Use each page's `description` as its line.

## log.md

```markdown
# Wiki Update Log

## 2026-11-12
* **Creation**: Added [Intel Arc Vulkan support in llama.cpp](/topics/arc-vulkan-llama-cpp.md) from a Claude research report.
* **Update**: Added Arc results to [B580 benchmarks](/topics/b580-benchmarks.md).
```

Date headings are `YYYY-MM-DD`, newest first. Add to today's heading when it exists.

## Filing research (do this after every research task)

When a research subagent finishes, file its report before you reply, unless the owner said not to save it.

1. Save the report unchanged as `references/<date>-<slug>.md`, with its source URLs in `sources`.
2. Find the topic pages it affects with `wiki_search`, searching for the report's main subjects, and
   check `index.md` for anything it missed.
3. Update those pages, or create new ones: merge the new facts in, cite the report and its original
   sources, and note any contradiction with what a page said before rather than silently overwriting it.
4. Run `wiki_related` on each page you created or changed, and add links between related pages in both
   directions.
5. Update `index.md` and add the changes to `log.md`.
6. In your reply, mention which pages you created or updated.

Research filed here is knowledge about topics. Facts about the owner themselves belong in memory, saved with `memory_remember`, not the wiki.

## Answering from the wiki

When the owner asks about something the wiki might cover, search it with `wiki_search`, using their
question in plain words. It matches by meaning, so "knowing when someone's in a room" finds pages about
presence sensors. Open the pages it returns with `read_file` and answer from them, citing pages by link.
If the search tool fails, fall back to reading `index.md`. Say when a page is past its `stale_after` date, unverified, or
deprecated. If the wiki doesn't cover it, say so and offer to research it.

## Linting (when asked)

Check the whole wiki and report, then fix what the owner approves:

- files missing frontmatter or `type`, and pages missing from `index.md`
- links to missing pages, and pages nothing links to
- footnotes whose label isn't a `sources` id
- pages past their `stale_after` date
- claims that contradict each other across pages
- topics mentioned often that have no page yet
