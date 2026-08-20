# 008 — Ports are contracts, not a checklist

| Field         | Value                          |
| ------------- | ------------------------------ |
| **Date**      | 2026-08-02                     |
| **Status**    | Accepted                       |
| **Supersedes** | ADR-001, in part               |
| **Deciders**  | Maintainer                     |

---

## Context

[ADR-001](001-hexagonal-architecture.md) established ports and adapters, and it
was right to. What it also said, in its Consequences, was:

> Adding a new driver requires only implementing the twenty port adapters.

Read as a requirement rather than an upper bound, that sentence produced code.
The Linux driver shipped **nine adapters with no production caller** — 1 549
lines across `app_launcher`, `clipboard`, `graphics_renderer`, `key_state`,
`mouse_control`, `network_info`, `notifier`, `tooltip_renderer` and
`window_manager`. Every one of them passed the presence check, passed the port
compliance check, and was reached by nothing.

The failure is not that the code was wasted. It is that it was **indistinguishable
from working code**:

- `linux/README.md` listed "Tooltip overlay — not implemented", and next to it
  an adapter that shells out to `yad`/`zenity`. Both statements were true and
  they read as contradictory.
- A reader looking for how Linux notifies found `adapters/notifier.lua`, a
  complete implementation, and no answer to the question — because nothing calls
  it.
- The presence test asserted the nine existed. It was written from the same
  sentence, so it could only ever confirm the checklist had been completed.

Measured across all three drivers before the change: macOS 24 adapters / 0
unreferenced, Windows 21 / 0, Linux 23 / **9**. The pattern is not general
carelessness — it is one driver that was told to fill in a form.

## Decision

**A port is a contract for the drivers that need the capability. It is not a
checklist every driver must complete.**

- A driver implements the ports its features actually use. An absent adapter is
  a legitimate, readable statement that the driver does not do that thing.
- An adapter that exists must be reachable. `tools/test/test-adapter-reachability.cjs`
  ratchets the count of unreferenced adapters per driver, and all three are held
  at **zero**.
- The presence test is inverted accordingly: it no longer asks "does every
  declared port have a file?" but "is every file this driver ships loadable and
  required by something?". The old direction could not catch the defect; a
  missing adapter is loud — the require fails at boot — while an unreachable one
  is silent, and silence was the whole problem.
- The port contracts themselves are unchanged. All twenty remain real: every one
  has traffic on macOS, Windows, or both. Shrinking `contracts.json` was
  considered and rejected — the ports are not the thing that was wrong.

## Consequences

### Positive

- The tree answers "does Linux do X?" correctly by inspection.
- 1 549 lines and five test files deleted, with nothing to migrate: no caller
  existed.
- "Adding a driver" is now sized by what the driver does, not by a fixed twenty.
- The reachability ratchet makes the class of defect impossible to reintroduce
  quietly: a new unreferenced adapter fails on the first one.

### Negative / Trade-offs

- A driver can now silently lack a capability another has. That is a real loss
  of symmetry, and it is the point: the symmetry ADR-001 asked for was being
  satisfied by files rather than by behaviour. The honest record of what each
  driver implements lives in `linux/README.md`'s capability table and in the I1
  tree-parity gate, both of which describe behaviour.
- Restoring one of the deleted adapters means writing it against its port spec
  again. The specs are unchanged, so this is re-implementation, not archaeology
  — and it will arrive with the caller that motivated it, which is the order
  that was missing.

## Notes

The deleted adapters are in this repository's history at
`static/ergopti_plus/linux/adapters/` up to the commit that removed them. They
were never wrong code; they were code with no reason to run yet.
