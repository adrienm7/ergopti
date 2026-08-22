---
name: orchestrate-pass
description: Orchestrate a bounded multi-agent pass with independent verification. Use when one context cannot cover the task safely.
---

# Running a multi-agent pass

Fan-out earns its cost on breadth — many files, many independent questions. It
does not earn it on depth, and it never earns it on writing.

## Scout first, then fan out

Discover the work list in your own context (list the files, find the sites, scope
the diff), *then* parallelise over it. Fanning out before you know the shape
produces agents that each rediscover the same landscape.

## Read-only fan-out, sequential writes

Agents research and verify. **You** implement, one commit at a time. Parallel
agents editing the same tree conflict on shared files — `tests/run_all.ahk` is the
obvious one, since every new test must be registered there.

## Feed them what has already been rejected

The single highest-value thing you put in an agent prompt. Without it they will
confidently re-propose ideas this repo already tried and reverted — tooltip window
reuse, chunking the emoji registration, process-priority changes. Extract the
rejected list from `docs/PROJECT_MEMORY.md` and paste it in with the *reasons*.

Also give them: the real paths (including the config redirect, see
`perf-profiling`), the conventions that make a proposal undeliverable, and the
evidence standard — every claim carries `file:line`, and every number is labelled
**measured** or **deduced**.

## Verify with two independent lenses

One refuter is a coin flip. Two agents looking from *different angles* is what
catches a plausible-but-wrong finding:

- **Code lens** — does the cited code actually do this? Recount the per-keystroke
  cost yourself. Is the transformation correct in this language?
- **Memory and convention lens** — does this re-raise something rejected? Is the
  cache invalidation provable? Does the named test exist, and does it cover the
  invariant?

One refutation kills the finding. In practice this rejects roughly half, which is
the point.

**A refutation is a hypothesis too.** Verify the verifier when the stakes are
high: a lens once dismissed a measured 38 ms parse as "implausible, realistically
2-5 ms". Re-benching gave 44.3 ms — the finding was right and the refutation was
wrong. Cheap to check, expensive to get backwards.

## Structural results, not prose

Give agents a schema. `agent(prompt, { schema })` returns a validated object, so
you get `file`, `line`, `verdict`, `evidence` as fields instead of parsing an
essay. It also forces the agent to commit to a shape — an agent that cannot fill
`preuve` usually has not verified anything.

## Agents read a moving tree

A long pass overlaps with your own edits and with concurrent branches. Their
line numbers are stale on arrival — **re-read the site before applying an edit**,
and match by symbol rather than by line. One recon in this repo reported findings
against files that had changed under it mid-run, and correctly said so.

## Resuming

A workflow persists its script and returns a `runId`. After a mid-run failure —
an agent dying on a schema mismatch, a stop — relaunch with
`{scriptPath, resumeFromRunId}`: the unchanged prefix replays from cache and only
the failed and subsequent calls run live. Do not edit the script before resuming
unless you *want* the tail re-run: the cache key is `(prompt, opts)`.

## When not to do this

A single-file question, a known symbol, a mechanical edit, or anything where you
already know the answer and just need to type it. And never for the final write-up
— synthesis is where you add the value the agents cannot.
