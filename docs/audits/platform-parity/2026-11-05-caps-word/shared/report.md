# Shared CapsWord policy and declaration audit

Audited source: `f2a7dba5fc580aad61e6a0ed16ede84406aed2b0`, November 5, 2026.
This scope reviews the shared policy, AHK port, manifest, action identities,
parameter menu and public inventory. Driver reviewers own native admission and
runtime publication. No production or registered test source was changed.

## Confirmed findings

**CW-S001 — Low severity, high confidence: an accepted positive delay can become
opposite policies after millisecond quantization.**

Set `shortcuts.caps_word.idle_timeout_seconds = 0.0001` in a valid canonical
configuration. This is a hand-edited or programmatic value; the ordinary menu
only offers whole-second presets. Both policy ports accept positive fractional
seconds and round 0.1 ms to zero. In actual Lua 5.4 and LuaJIT, zero remains an
enabled numeric delay because disabled is represented by `nil`:
`idle_expired(policy, 100, 100)` returns true. The AHK port's source represents
disabled by zero and requires `idle_ms > 0`, so the same rounded positive value
disables automatic expiry there. No AHK execution is claimed.

The retained `policy-probe.lua` executes the actual shared owner and corpus.
Controls cover zero (disabled), 0.00049 s (rounded zero), 0.0005 s and 0.001 s
(both one millisecond), and 2.5 s (2500 ms). One-millisecond controls remain
active at the activation clock and expire at the exact one-millisecond boundary.
The Linux reviewer separately records actual Manager admission queueing a
zero-delay callback, and macOS records the actual watcher scheduling it. Those
are controlled event-loop/timer ports, not native desktop timing measurements;
the root must replay those driver artifacts before aggregating their claims.

The shared corpus misses the collision: it covers zero, whole seconds and 2.5 s,
but no positive value rounded to the disabled sentinel. A regression should define
one cross-driver rejection or minimum-positive quantization rule, preserve zero
as disabled, and exercise both actual policy ports plus public timer admission.
It must not invent a requirement that a sub-millisecond native timer can deliver
precise physical timing. The property violated is cross-driver idle-policy parity,
not an unmeasured lag, crash or universal missing-output guarantee.

**CW-S002 — Low severity, high confidence: the checked delimiter caption can name
one scalar while the active policy listens to another.**

Choose the valid magic key `§` through the actual driver owner, select only
CapsWord's built-in `star` delimiter, and isolate pointer and idle causes. The
macOS/Linux menu substitutes `§` in that checked row, but the active mode still
stops on literal `★`; typing `§` leaves it active. The OS reviewers retain actual
public menu/event programs, and the root independently replayed the shared and
macOS controls before adjudicating this common finding. This is not a physical
native keyboard receipt.

The underlying ownership differs. macOS changes the shared terminator catalogue
by replacing the star definition's character table; a policy module loaded before
that mutation keeps the previous table. Linux's public magic-key owners update
their metadata without a production `Terminators.update_magic_key` caller, so its
CapsWord policy stays literal. The shared `magic-key-policy.lua` independently
executes real mutation and module loads: loading the policy before the rename
matches `★`, while loading it afterward matches `§`. It does not pretend to prove
every full startup order or that Linux invokes the macOS mutation route.

Windows explicitly documents a fresh built-in catalogue separate from hotstring
magic-key renaming; the full translated Windows caption remains unverified in
this shared scope. Therefore the proposed regression requires an explicit decision
between literal and dynamic slot meaning and consistent labels, rather than
blindly making all policies follow renamed magic keys. The confirmed property is
truthful setting labels; the intended common literal-versus-dynamic policy remains
unresolved. The shared corpus keeps the default `★`, where both meanings agree,
and does not couple public rename, actual menu and active output in one test.

## Actual execution and source evidence

The genuine Lua 5.4 and LuaJIT processes each run the actual registered shared
contract: eight registered cases with 166 assertions. The independent boundary,
Unicode, full-catalogue and malformed-value controls add 116 assertions, totaling
282 per runtime. These are assertions within a bounded policy scope, not 282
independent user features. The full catalogue has 25 built-in slots and 26
characters because one Enter slot owns both CR and LF.

`declaration-probe.cjs` loads the actual feature model, validates its eight
CapsWord settings and requirements, compares all 24 generated OS flags, checks
the actual menu's closed presets and aliases, and opens every current shared
locale file. All required captions and the Windows gesture reason exist in all
21 locales. These declarations do not prove native capability or keyboard
receiving. `single-source-gate.txt` retains the existing repository gate, and
`false-greens.txt` retains the mechanical ratchet result; neither is treated as a
semantic parity certificate.

`source-contract.py` authenticates ten positive source relationships over seven
exact files, including the AHK expressions and Lua settings/timer ownership.
Its source-only output never evaluates a Python clone of AHK. The broader
`source-receipt.json` authenticates 49 named source inputs and reviewed neighbors,
including all 21 locale files; it is not a transitive dependency closure.

## Policy, intended differences and qualifications

- The parameters have shared defaults and recommendations: 10 s idle, eight
  delimiters (`space`, `nbsp`, `nnbsp`, `tab`, `enter`, `comma`, `semicolon`,
  `period`), and all supported pointer switches true. They are settings of a
  user-activated mode, not independent automatic activation features.
- Zero disables the idle rule. Presets are 0, 1, 3, 5, 10, 30, 60 seconds; free
  menu input is deliberately absent, while canonical configuration accepts
  validated nonnegative fractions.
- Every checked built-in delimiter is tested by typed output. A mixed payload
  terminates when any checked scalar appears, including the French no-break
  spaces and an astral-prefix control. Unchecked punctuation does not terminate.
  This is a policy result, not proof that every driver feeds the right payload.
- User-added hotstring delimiters are deliberately excluded from CapsWord's
  choices and validator. The actual corpus explicitly appends and removes a
  custom delimiter to test this boundary.
- `caps_word` on Windows/Linux and `capsword` on macOS are explicit action
  equivalents. `toggle_capslock` is a separate action; spelling differences are
  not missing features. Direct selection-menu placement is Linux-specific, with
  other OSes using their existing action and binding surfaces.
- Windows omits the gesture pointer setting with an explicit translated reason:
  its current native surface does not observe the gestures kept by the OS.
  macOS/Linux declare that kind. This is not a claim that no future Windows
  implementation can observe gestures through another interface.
- Windows explicitly publishes auto-off settings for the next activation.
  Linux Manager also retains a session snapshot, but its actual menu explicitly
  promises published changes apply to the running session's next event. That
  contradiction belongs to the Linux finding; it must not be presented as an
  intentional permanent difference. macOS's settings owner promises live apply
  on the next event; its timer scheduling still needs driver-level evidence.

## Qualified numeric and catalogue gaps

An accepted finite `1e308` seconds overflows conversion to milliseconds in both
actual Lua runtimes: the compiled delay becomes positive infinity, and a finite
clock does not expire it. This is a characterized unbounded-conversion gap only.
No actual native timer admission or Windows arithmetic was executed for that
value, so there is no second confirmed finding or invented crash claim.

The magic-key ownership evidence is now part of CW-S002 above, with public
macOS/Linux corroboration and explicit per-OS submechanisms. It remains separate
from a product decision to prefer either literal or dynamic meaning.

## Coverage, dry passes and remaining gaps

The 25 rows in `coverage.json` identify the outcome, basis, evidence and limit of
each reviewed aspect. Two final bounded A/B sweeps repeat policy/corpus execution
under both runtimes, both magic-key characterizations, declaration checks and
pinned source checks without another confirmed root after CW-S002. Repetitions do not add distinct coverage or establish exhaustive
native parity. Each final sweep runs six processes; the repeated executions are not counted as
additional user features.

No native keyboard, compositor, real Hammerspoon timer, Windows AHK process,
application receiving, timing-lag or long-duration memory-growth measurement was
performed in this shared scope. Timer, watcher, lock and callback retention need
the actual per-driver owners. Native requirements and lifecycle admission are
kept separate from successful pure-policy tests. No previous CapsWord root was
found in the earlier audit reports/TODO searches used for this scope; that search
is deduplication context, not proof no historical issue can exist.
