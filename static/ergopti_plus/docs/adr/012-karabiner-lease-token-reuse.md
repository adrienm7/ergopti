# 012 — Reusing a Karabiner lease token on recovery: refused until the tombstone can be rearmed

| Field        | Value      |
| ------------ | ---------- |
| **Date**     | 2026-10-23 |
| **Status**   | Accepted   |
| **Deciders** | Maintainer |

---

## Context

Every Karabiner lease generation owns a random 32-hex token. The token is part
of every driver-owned variable name in `karabiner.json`
(`ergopti_mode_<token>`, `ergopti_revoked_<token>`, `ergopti_layer_active_<token>`,
`ergopti_ke_held_*_<token>`) and of every rule's ownership marker. A lease
recovery after a failure therefore allocates a new token, rewrites the whole
743 KB file and makes Karabiner reload every rule, personal ones included,
while the user types (issue #99: 28 of 33 deploys on 2026-10-19 were recovery
deploys; a reload can stall or swallow a key). Deferring the deploy to a typing
pause (`deploy_pacing.lua`) bounds the damage but not the rewrite.

The one-token-per-generation rule is a safety guarantee, made of three parts:

1. **No late writer reaches a live generation.** A worker, revoker or guardian
   of generation A can only write A's variables; B's rules read B's variables.
2. **Monotone tombstone.** Ending a generation (stop, failure fence, guardian
   fence) writes `mode=0` and `revoked=1` and never lowers `revoked`
   (`RemapLeaseWorker.swift`, "Monotone Tombstone"). Rules require `revoked=0`.
3. **No ambiguous token history.** The ledger `karabiner.used_tokens.v1` keeps
   every published token across reloads, so a repeated UUID or an unreadable
   ledger never yields a token with stale `revoked=1` and an honest-looking
   READY.

## Decision

Do not reuse tokens. Keep one fresh token per generation, and record every
allocation decision so the next Mac log shows what a reuse would have had to
overcome.

Why reuse cannot be made safe here: a recovery follows a fence, and a fence has
published `revoked_<token>=1` for the token. The replacement's rules require that
variable to be `0` and no existing writer ever lowers it, so the same token can
never reach READY. Lowering it is a new native operation (an acknowledged
"rearm" of one token, performed only after every writer of the previous
generation has retired) and it deliberately breaks guarantee 2 for that token.

The stricter condition under which the guarantees would still hold, for a
future change that includes the native rearm:

- **Previous writers retired with an acknowledgement.** The previous
  generation is in no `retiring` set entry that is not `safe`, its fence
  completed, and its outer and inner roles were reaped (not merely signalled).
  Guarantee 1 is kept by this condition instead of by token uniqueness.
- **Crash.** If Hammerspoon dies between the rearm and READY, the surviving
  native role fences the token again (`revoked=1`); the ledger already holds the
  token, so a restarted driver allocates a fresh one. A rearm must be persisted
  in the ledger as "rearmed" before the native write, so an ambiguous crash is
  read as "tombstoned".
- **Stale guardian.** The guardian record is exact-token and durable. A rearm
  must first clear the record of the previous generation (acknowledged),
  otherwise the guardian would fence the reused token a second later.
- **Late writer.** Any writer not proven reaped keeps the decision at
  `writers-unaccounted`: the token is not reused while one exists.

None of these steps can be exercised without Karabiner's Core Service and the
launcher on macOS, and the Swift launcher is not compiled on the Windows host.
Shipping the Lua half alone would either never trigger or, worse, trigger
against a native side that cannot rearm.

## Consequences

### Positive

- No guarantee is weakened. Every regression test pins the refusal.
- `Logger.evidence` records `Lease token decision=fresh reason=<name>
unaccounted_writers=<n> ledger_size=<n>` at each allocation (no token, no
  content), and the deploy decision line now carries the synchronous write
  duration next to the byte size (`written in <n> ms`).

### Negative / Trade-offs

- Each recovery still rewrites and reloads `karabiner.json`; only the typing
  deferral limits the effect.

### Neutral

- `platform/remap/token_reuse.lua` is the single place that names the reasons.

## Alternatives considered

| Alternative                                     | Why rejected                                                                        |
| ----------------------------------------------- | ----------------------------------------------------------------------------------- |
| Reuse the token once writers retired (Lua only) | The tombstone stays `1`; the replacement cannot reach READY.                        |
| Lower `revoked` through the existing CLI writer | Breaks the monotone tombstone for a token whose late writers are not provably dead. |
| Fixed variable names with a generation counter  | Same stale-writer exposure, plus a rewrite of the generator and every consumer.     |

## Evidence in the codebase

- `platform/remap/token_reuse.lua`, `platform/remap/lease_controller.lua`
  (`create_generation`), `platform/remap/generator.lua` (deploy decision line).
- `tests/unit/platform/remap/lease_controller/test_token_reuse.lua`; existing
  invariants: `test_generation_isolation.lua` (no allocation while a failed
  writer is unfenced), `test_publication.lua` (identical bytes are never
  rewritten), `deploy_pacing.lua` (typing pause).
