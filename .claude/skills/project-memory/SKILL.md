---
name: project-memory
description: How to consult and extend docs/PROJECT_MEMORY.md, the in-repo shared engineering memory — entry format, slug convention, TOC bullet, and what belongs there versus in a commit message. Use before non-trivial work in an unfamiliar area, and after learning something non-obvious about this codebase.
---

# Project memory

`docs/PROJECT_MEMORY.md` is the single source of truth for hard-won knowledge:
foot-guns, architectural invariants, and the conventions the maintainer insists
on. It is shared by every developer, agent and reviewer — it replaces any
agent-private memory store. If you keep a private memory, the pointer there
should lead here.

## Consult it first

Before non-trivial work, read the entries covering the area you are about to
touch. A meaningful share of "new" bugs in this repo are documented recurrences —
the entry usually names the exact mechanism and the fix that was chosen last time.

## What belongs here

Something **non-obvious** and **durable**: a foot-gun that cost real debugging
time, an invariant that is not visible from the code, a decision whose rationale
would otherwise evaporate, an intentional asymmetry that looks like a bug.

What does **not** belong: anything the repo already records — code structure, the
content of a fix (that is the commit), git history, or rules already written in
`.github/copilot-instructions.md`. Do not restate; link instead.

## Entry format

Body entries sit under `## Working conventions & feedback` (how we work) or
`## Project architecture & decisions` (how the code is).

```markdown
### slug-with-dashes

_One-line italic summary — this is what a reader skims_

<sub>slug: `slug_with_underscores`</sub>

The fact, stated concretely. Name files, constants and mechanisms.

**Why:** the reasoning or the incident that produced this knowledge.

**How to apply:** what a future reader should actually do differently.

Related [[other_slug]].
```

Then add the matching bullet to the `## Contents` TOC at the top, under the right
heading:

```markdown
  - [slug-with-dashes](#slug-with-dashes) — the same one-line hook
```

Conventions: dashes in the heading and anchor, underscores in the `slug:` line
and in `[[links]]`. Link liberally — a `[[link]]` to an entry that does not exist
yet marks something worth writing, it is not an error.

## Writing well

- **Be concrete.** "Guard the map access" is useless; name the file, the key, the
  failure mode, and what the symptom looked like.
- **Convert relative dates to absolute.** "Last week" is meaningless in six months.
- **Record the symptom, not just the cause** — that is the string a future reader
  searches for when they hit it again.
- **Check for an existing entry first** and extend it rather than adding a near
  duplicate. Delete entries that turn out to be wrong.
- **Verify before trusting.** Entries reflect what was true when written. If one
  names a file, function or flag, confirm it still exists before acting on it —
  and correct it if not.

## Cadence

Add entries proactively at the end of a task, without being asked. Then commit —
without pushing, per the `commit-and-push` skill.
