# Linux expansion undo and magic-key repeat audit

Audited commit: `b17e47ed3bb92c106703d3e3482b3c2973f5bc1e`.

**Two confirmed mechanisms:** `URL001` resets the matcher after an acknowledged
repeat, losing subsequent repeats/corrections and inventing a word start;
`URL002` drops the private ancestry of a repeated scalar from a real personal
prefix expansion. Immediate Backspace restoration exists on Linux, with the
explicit limits below. No production or registered test code was changed.

## Execution and boundary contract

`owner-probe.lua` reads and compiles the actual complete `handle_char` and
`handle_control` closures from Main. It executes the real Linux/shared engine,
RepeatKey, WordReset, magic-key/terminator owners, shipped TOML loader,
personal-prefix producer, injector, output transaction, logger and focus guard.
The recording ports are the native keyboard channel, XKB character map,
resident accessibility observations, clock, ambient app identity and telemetry
receiver. Clipboard entry points explicitly throw if reached: all twenty cases
use the admitted keyboard route. The controlled channel applies emitted DOWNs
to a Unicode-scalar text model. This is actual Lua business-owner execution;
the text model is **not a native editor receipt**. No native clipboard,
user configuration, real input device or desktop service was accessed.

The script loads all 14 shipped `repeat_corrections` entries through the real
loader for the correction cases. The private case uses the real
`Prefix.build` producer with a synthetic SSN, not a handwritten private mapping.
The settings resolver in the callback environment supplies a two-second window;
all physical steps advance ten milliseconds, so these cases do not certify
production configuration resolution or exact timing thresholds. The existing
isolated modules cover those owners separately.

Both LuaJIT and Lua 5.4 execute all **20 owner cases**. Nine existing registered
modules run in fresh LuaJIT processes: **412 passed, zero failed**. The final A
and B sweeps repeat those same cases; they are not additional distinct coverage.
See `final-A-receipt.json`, `final-B-receipt.json` and their named outputs.

## URL001 — Repeat publication forgets the word and its boundary

Severity: medium. Confidence: high. Guarantee: G2.

Main synthesizes its repeat result with `final_result = true`
(`ergopti_hotstrings.lua:1382-1392`). On successful delivery the common commit
branch applies the output, then calls `engine:reset(nil, nil, "keep")`
(`:1483-1487`). That empties the matcher and declares a new word boundary;
`keep` preserves only the AI context, not the matcher. The existing pure
`RepeatKey.resolve` corpus never executes this publication branch.

Decisive real-owner observations:

| Case                                             | Observed keyboard-model result      | Control or intended continuity                                                 |
| ------------------------------------------------ | ----------------------------------- | ------------------------------------------------------------------------------ |
| `po`, magic, magic                               | `poo★`; only the first repeat fires | Retaining `poo` allows another repeat                                          |
| `ac`, magic, `ê` with shipped corrections loaded | `accê`; matcher contains only `ê`   | Manual `accê` gives `accu` through the real `ccê → ccu` row                    |
| Word-only auto mapping `x → z`; `po`, magic, `x` | `pooz`                              | Manually typed `poox` stays `poox`; the mapping must not fire inside that word |

There is no output error: the first edit succeeds and the logical commit itself
destroys the context. The later absence or wrong mapping has no diagnostic.
Windows' transient repeat has `FinalResult: false`
(`windows/infra/hotstrings/hotstring_engine_main.ahk:HSE_TryRepeatKey`);
macOS commits the full `next_buffer`
(`macos/modules/keymap/expander.lua:try_repeat_feature`). Those comparisons are
source-derived in this role; the other OS reviewers own their execution claims.

A regression must drive the real caller through acknowledged repeat output,
then assert a second repeat, shipped false-positive correction and refusal of
word-start-only mappings inside the retained word. Keep failure and disabled
controls. Fixing the standalone pure rule would not cover this root.

## URL002 — Repeating private prefix output publishes a public scalar

Severity: medium. Confidence: high. Additional property: private-output
classification. No G1–G5 guarantee is stretched to mean privacy.

The real prefix producer declares `is_private = true` and
`final_result = false` (`prefix_rules.lua:59-65`), so its acknowledged result
legitimately remains in the matcher. The shared engine carries that private flag
on the mapping result, but the retained word has no corresponding private
ancestry for the later fallback. Main builds the repeat result without
`is_private`, then sends it through the ordinary output and telemetry branch.

The proof builds the actual SSN prefix mapping from synthetic
`123456789012349`, types `12345` to expand it, then types the magic key. The
first injector call is private and withholds its payload. The probe explicitly
enables TRACE logging. The repeat emits `9` with `private = false`; at that level
the actual logger records
`inject(): bc=1 text='9'…`, and Main calls the telemetry receiver with the same
unclassified replacement. The payload-bearing diagnostic is conditional on
TRACE; this observation does not establish its emission at the default log
level. Main's public telemetry classification is the default-path observation.
`9` was not in the physically typed prefix. The actual
metrics owner distinguishes private redaction and event publication in
`keystats.lua:1092-1128`; persistence of a real database was not executed here.

Only one scalar is demonstrated, not exfiltration of the whole SSN. This is
derived synthetic output from an explicitly private owner, not a requirement to
suppress every ordinary user character after private input. The private-Undo
positive control restores `12345` with `private = true`, showing that the
classification loss is in the new repeat result rather than the general
injector interface.

A regression must use real prefix production and actual Main repeat dispatch,
then assert preserved private classification at output, logger and metrics
boundaries. Include ordinary repeat and private Undo controls. Decide an explicit
safe policy for derived output; do not simply suppress unrelated later typing.

## Availability, intentional differences and behavior limits

- Repeat is declared on all three OS, default off and recommended on. Linux
  requires evdev/uinput (`manifest.toml:510-526`). Its public menu row uses the
  actual `RepeatKey.toggle`/`is_enabled` owner
  (`ui/menu/menu_hotstrings.lua:1480-1496`). This is presence, not full parity.
- Linux observes text already forwarded by the grabbed hook. Repeat erases the
  magic key alone and types one copy; macOS can consume the physical completing
  event. Different primitive erase spans follow event ownership, not a missing
  repeat feature (`repeat_key.lua:250-255`; routed typing-order memory).
- The fallback deliberately comes after registered matches. The real mapping
  positive control wins. Doubling is intentionally absent from preview; routed
  `project-the-bubble-never-offers-a-doubling` records the maintainer's policy.
  Shipped repeat-correction mappings remain separate catalogue entries.
- Repeat uses the shared **codepoint** word rule and excludes custom delimiters.
  Non-BMP and combining-codepoint cases execute. No grapheme-aware native
  deletion guarantee is inferred from those scalar-model controls.
- Linux's immediate bare/Shift-Backspace restoration is a driver feature. It
  consumes the stored expansion receipt once, compensates for the physical
  Backspace already forwarded, and restores the original trigger. Nonconsumed
  terminators count in the remaining output. Ordinary typed input, controls,
  pointer/focus/capture loss and pause end that window. A modified Ctrl/Alt/Super
  Backspace follows word/navigation handling, not expansion restoration.
- **Empty-output exception:** an accepted literal empty replacement without a
  replayed terminator still arms a receipt, but `remaining >= 1` fails when
  Backspace arrives. The receipt is dropped; the application's already-forwarded
  Backspace remains and can delete the preceding character. The scalar model
  shows `PRE` + `xy → ""` + Backspace becoming `PR`, with no restoration call.
  With an empty replacement plus replayed Space, the physical Backspace removes
  Space and the trigger restores (`PRExy`). This is an explicit current behavior
  limit, not a claimed extra synthetic erasure or new guaranteed G2 violation.
- Outputs containing key tokens deliberately do not publish Undo: the caret is
  no longer known. Application Ctrl+Z, editor undo grouping, line-joining,
  selections, rich text and target consumption remain application/native
  receiving concerns; emitting input is not certification of those behaviors.

## Counterchecks and final sweeps

The failure control refuses the first synthetic DOWN. The real transaction
returns failure, the hook emergency-stop port is called once, and Main publishes
neither telemetry nor Undo. It logs loudly; this is not a silent-failure finding.
Normal private Undo preserves classification. Existing actual-owner Undo tests
also retain the original destination across logger, clipboard read/write and
erase-settle transitions and refuse successor fields. Their clipboard uses
controlled native ports; those passes do not certify live clipboard ownership.

Pointer invalidation was re-read through Main's real `on_click` →
`secure_focus_guard.invalidate` → `reset_text` callback: it clears Undo
synchronously. Pause, input-capture blocking, desynchronization and focus-change
callbacks also clear it. A source-level absence of `_undoable = nil` directly in
`on_click` would have been a false positive. A discarded private-TOML hypothesis
also proved too broad: the shared Reader returns a fixed field set without
`is_private`; this role therefore uses the real prefix producer for URL002 and
does not claim a supported private TOML contract from loader comments alone.

Final sweep A revisited entry points, neutral/default/config writer behavior,
magic/word/delimiter predicates, registered-match precedence, acknowledgement
publication, Unicode, private ancestry and immediate Undo compensation. Final
sweep B revisited pause/focus/input-capture/desync/reload ownership, control and
pointer retirement, native refusal/cleanup, preview policy, telemetry and the
same rejected hypotheses. Both replayed all twenty owner cases under both Lua
engines and the nine isolated registered modules; no further distinct root was
confirmed. The existing pure repeat corpus and its test description explicitly
limit themselves to the rule, which explains why passing it does not refute
URL001. The false-green mechanical ratchet reports zero patterns; manual owner
review remains necessary.

## Coverage gaps and memory watch-list

No live Linux desktop, evdev/uinput device, Wayland/X11 application, AT-SPI
service, clipboard manager, editor selection or app-native Undo was exercised.
The focus watcher and output channel are recording native ports. No measured
runtime latency, memory profile or G4 claim is made. The shared matcher bounds
its rolling buffer to 256 codepoints; RepeatKey caches its configuration, and
Undo retains only one receipt. Those are source observations, not heap or
resident-secret-erasure measurements. Native modifier/dead-key/IME/compose,
grapheme deletion and editor-specific reflow still need device/desktop testing.

The source receipt names exact files and hashes, not a claim that every
transitive dependency in the repository was audited. `coverage.json` records
which statements are source-derived versus executed and where the intentional
rules or gaps come from. Older LH-001/002/003, clipboard LCP-001/002/003 and
personal-info PIL-001/002/003 have different roots; they are not re-added here.

## Replay

```sh
PATH=/workspace/scratch/parity-toolchain/ci-bin:$PATH LOGNAME=agent \
  luajit owner-probe.lua /path/to/ergopti
python3 run-proofs.py /path/to/ergopti --pass-name review
```

The first command is the decisive program; the second repeats it under LuaJIT
and Lua 5.4 and executes the nine registered modules. Read the JSON observations
and source owners independently; passing these programs documents current
defective behavior and positive controls, not a production fix.
