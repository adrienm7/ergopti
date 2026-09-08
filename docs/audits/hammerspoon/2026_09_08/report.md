# Hammerspoon keycode accounting audit

Audited commit: `21bdd7c861f08ab296f31d22f8c7c342e2cd9638`.
Date: 2026-09-08. Scope: the keylogger callback, Karabiner physical ledger,
output suppression set and aggregation walkers. This is a bounded follow-up,
not a complete driver audit.

## Summary

HS-274 remains open. The current callback double-counts managed output.
The apparent one-line fix was rejected: activating the global suppression set
loses ordinary physical keys sharing a remapped output code. No production
change from this candidate is retained.

## HS-274 — physical and remapped keycode credits lack exact ownership

Severity: medium. Confidence: high. Guarantee: G2.

The callback in `modules/keylogger/init.lua` constructs `meta.kc` with
`managed and nil or keycode`, which always retains the output keycode.
`aggregator/events.lua` credits both that typing metadata and a separate
`karabiner_press` record. The physical heatmap therefore counts two keys for
one remapped press.

Reproduction uses the real callback and aggregation walkers, with a controlled
bridge classification and an explicit physical ledger record. From
`static/ergopti_plus/macos`, run:

```text
lua ../../../docs/audits/hammerspoon/2026_09_08/proofs/duplicate-count.lua
lua ../../../docs/audits/hammerspoon/2026_09_08/proofs/physical-collision.lua
```

These are standalone audit probes, intentionally outside automatic test discovery.
The first is expected to exit 1 on the audited commit: its desired invariant is
not satisfied. The second is a passing safety control on that same commit.

Measured against the audited source:

- Ordinary-key control: output keycode 0 has count 1; physical keycode 36 absent.
- Remapped case: output keycode 0 and physical keycode 36 both have count 1.
- Real suppression-set collision control: physical Space retains count 1.

Why existing tests missed this: they tested set membership and bridge aggregation
separately. The new duplicate-only regression also passed a harmful candidate,
because its ordinary-key control explicitly declared the key unmanaged.

## Rejected correction and independently reproduced collision

[The rejected patch](proofs/rejected-keycode.patch) explicitly assigns nil when
the keycode belongs to the managed output set. It passed 9,528 HS tests,
216 JS checks and 67 E2E scenarios (one driver-specific skip), but those results
did not cover the collision below.

A valid configuration is:

```lua
escape = { tap = "space", hold = "none" }
spacebar = { tap = "none", hold = "none" }
```

The real action catalogue maps `space` to `spacebar`.
`kc_bridge.build_managed_output_set` consequently classifies code 49 as managed.
However, `generator.build_tap_hold_rule` explicitly emits the `none/none`
Space passthrough without a physical ledger event. With the rejected patch,
the collision probe reports `physical_space_count=nil` and exits 1.
Its real callback still records the logical space, but the heatmap loses its
only physical credit. This was reproduced, not inferred from a passing suite.

Do not apply the archived patch to an active checkout to repeat this experiment.
Use an isolated disposable source snapshot if candidate replay is necessary.

## Required correction and regression obligations

1. Establish exact event ownership or an exhaustive authoritative physical-input
   source before suppressing a Quartz keycode.
2. Preserve both duplicate-count and physical-collision invariants. Exercise the
   actual configuration-to-set boundary, not only a classification stub.
3. Cover passthrough, mixed none/action slots, combos, modifiers, repeat,
   private/paused contexts, lease transitions and multiple keyboards.
4. Keep logical text and non-synthetic classification independent from physical
   key attribution. Do not hide this failure by dropping text or marking it synthetic.
5. Prove producer/consumer ordering under asynchronous ledger delivery and teardown.
6. Measure typing-path overhead on macOS before introducing a native transport.

The existing ledger carries only a physical name or release marker. It has no
shared output-event identifier. EventProvenance recognizes the driver's registered
SyntheticInput tags, not arbitrary Karabiner output. Matching by keycode, wall
time, event count or an assumed delivery order is not exact attribution.
Adding a shell command for every ordinary keystroke is not an acceptable
unmeasured performance change. A native producer capability must be verified
before choosing a design.

## Coverage and memory watch-list

Covered by executable probes: real key callback, logical event retention, real
aggregation walkers, real suppression-set construction and the collision above.
The collision action object faithfully models the existing catalogue entry;
catalogue and generator reachability were checked by source inspection.

Not covered: native Karabiner/Quartz delivery, physical keyboard/device provenance,
native performance, complete combo and modifier behavior, all driver entry points.
No latency or memory benchmark is claimed.

Relevant memory constraints remain active: exact provenance, no timing-based
self-observation filter, scoped fixture ownership, no blocking input callback.
No claim of a clean driver or exhausted audit follows from this pass.
