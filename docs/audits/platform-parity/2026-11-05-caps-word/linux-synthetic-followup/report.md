# Linux CapsWord synthetic-output consumer follow-up

Audited source: `f2a7dba5fc580aad61e6a0ed16ede84406aed2b0`.
Date: November 5, 2026.

This is a separately authorized follow-up on the same CapsWord module after the
initial Linux audit scope completed. Its initial report, 55 observation rows,
36 processes and two dry sweeps remain frozen. This follow-up adds **12 precise
observation rows** and two new bounded complete-program sweeps under genuine Lua
5.4 and LuaJIT: **four processes, all exit zero**. It does not retroactively add
these observations to the initial sweeps.

## Result and deduplication

The generic action catalogue emits checked Enter/Tab delimiters without notifying
CapsWord. This is retained as a **known-root consumer extension of WRSL-001**,
not a new CW-L003 or a second independent connector root. The earlier immutable
record is
`docs/audits/platform-parity/2026-11-05-word-reset/linux/findings.json`, pinned
there to `b17e47ed3bb92c106703d3e3482b3c2973f5bc1e`.

That prior root's catalogue branch explicitly identifies the same
`Gestures._execute_action → ComboEmitter → Writer` omission of canonical output
semantics, then demonstrates its word/AI arrow consequence. This follow-up adds
the CapsWord delimiter consumer and a different acceptance requirement. An
arrow-only WordReset/AI repair or regression does not establish CapsWord
Enter/Tab behavior. The implementation follow-up must include this consumer,
while preserving the known-root relationship and count.

## Exact reachable reproduction

For each delimiter independently:

1. Configure CapsWord idle timeout zero, terminators `["enter"]` or `["tab"]`,
   and all six pointer auto-off kinds false **before activation**. These pointer
   settings permit navigating a binding menu without first ending CapsWord.
   The shortcuts manager is enabled.
2. Activate the actual CapsWord catalogue handler while the real Hook fixture
   has a live captured input session. The actual lock API, emitter, broker and
   uinput writer acknowledge its CapsLock hold.
3. Store `primary_a = "enter"` or `"tab"` through the actual keyboard-shortcut
   settings owner. The source is a private real TOML file, not a fabricated
   assignment table.
4. Press physical Ctrl+A through the actual input-event encoder, reader and
   Hook. The XKB adapter is backed by native-shaped keysym values, including
   Control_L=0xffe3. Actual `Keyboard.consume` claims the chord, acknowledges
   deferral, and runs the real catalogue action on the queued loop callback.
   The live admission port explicitly admits the enabled/unpaused ordinary
   binding; full Main/secure-focus acquisition is not executed.
5. Observe exactly one recorded uinput `KEY_ENTER=28` or `KEY_TAB=15` DOWN and UP,
   each acknowledged by the actual writer over a recording syscall backend.
   CapsWord remains active and the capture lock remains on.
6. Press B next. The actual capture adapter returns uppercase `B`, and CapsWord
   still remains active. This is a capture observation, not a claim that a native
   receiving application was measured.

Direct `Gestures.execute_action("enter"/"tab")` controls produce the same
acknowledged delimiter wire and retained session. The gesture-reader switch is
left off in the fixture; the actual shared action catalogue remains available
for keyboard assignments independently, as production designs it.

## Positive controls and the important tap refutation

- Bare physical Enter/Tab takes the actual Hook semantic path and ends/unlocks
  the session when checked.
- The literal injector types the same newline/tab using the real layout-plan,
  transaction and writer owners over recorded native ports. Its output observer
  receives the payload once and forwards to the actual CapsWord manager, ending
  and unlocking the session. Main's installation/forwarding of that observer is
  separately authenticated source evidence; no Main closure is copied/executed.
- **Ordinary tap-action Enter/Tab already works.** The actual TapHoldEngine's
  `KEY_TAPS` table contains both IDs and emits native key rows back through the
  real Hook. A non-delimiter physical LeftCtrl tap configured to Enter/Tab yields
  one acknowledged native semantic key, ends CapsWord and invokes the generic
  catalogue tap callback **zero times**. This contradicts the initial broad
  hypothesis that all synthetic or tap Enter output uses the catalogue. Do not
  report that broader claim or require a fix for this positive path.

The state-preserving failure is therefore scoped to the generic action-emission
route, demonstrated through an actual logical keyboard assignment. It is not a
universal synthetic-input failure and not the prior word/AI arrow tap branch.

## Consumer omission and future regression

Main observes CapsWord text/control events from the Hook and literal text from
its injector observer. The generic action catalogue invokes ComboEmitter for
its generated Enter/Tab combo; this emitter has no CapsWord publication hook.
Own uinput output is intentionally excluded from physical observation, so it
cannot be relied upon to re-enter the Hook and discover the delimiter later.
The native output succeeds and no diagnostic identifies the missing consumer.

Extend the existing WRSL-001 implementation work to cover acknowledged generic
Enter/Tab output and the checked CapsWord policy. Keep the two controllers
separate: word/AI navigation rules are not CapsWord delimiter rules. Verify both
checked and unchecked states, acknowledged versus refused/partial output,
lifecycle/admission custody, exactly-once notification and the next typed key.
Preserve the working ordinary KEY_TAPS relay and literal-injector observer;
blanket synthetic feedback or duplicate notifications could break them.

## More precise modifier controls

The initial Linux fixture supplied Ctrl/Shift physical codes but returned no
modifier keysyms. Therefore its `ctrl-tab-checked` row does not prove that the
qualified Ctrl-modified control branch ran; a bare Tab path can satisfy that
assertion. Its Shift-code idle row likewise does not by itself establish the
Hook's actual modifier classification. Those frozen observations/counts are not
rewritten or promoted into stronger evidence.

This follow-up supplies the actual backend API shapes:
`key_sym(session, keycode) → numeric keysym` and
`sym_utf8(session, keysym) → text`, with Control_L=0xffe3 and Shift_L=0xffe1.
It asserts `Capture.modifier_role` before both controls. Real Ctrl+Tab now reaches
`onKey("tab", detail)` with `detail.mods.ctrl=true`, rather than `onChar("\t")`,
and ends the checked session. A genuinely classified Shift press/release at
9 seconds still produces no semantic event and the ten-second idle session
expires at 10 seconds. Modifier-only idle product intent remains unresolved;
this is corroboration of the qualified observation, not another finding.

Several fixture-construction attempts exposed missing fixture interface methods,
a mistaken engine method name, and the keysym conversion arity. These are not
driver findings and are not counted as successful final runs. The final program
imports real production functions unchanged and runs with the complete real
ConfigPaths surface except its private config-file selector. Its generic tap
expectation was explicitly refuted and replaced by the positive KEY_TAPS
assertions above, rather than weakening the observed contract.

## Replay and custody

`probe.lua` retains all 12 observations. `replay.py` gives each process a fresh
private TMPDIR, records exact program and runner hashes, and runs the frozen
follow-up twice under Lua 5.4 and LuaJIT. Every failed observation would return a
nonzero process status; all four final processes succeeded. `source-probe.py`
authenticates 23 scoped Git-pinned files and six qualified source relationships,
including the original WRSL-001 record and the working tap relay.

```sh
python3 source-probe.py /path/to/ergopti --output /tmp/caps-synthetic-sources.json
python3 replay.py /path/to/ergopti --output /tmp/caps-synthetic-results
```

These are actual Lua owners over faithful recording evdev/XKB/uinput ports, a
private real configuration file and controlled deferred callbacks. No physical
Ctrl+A, full Main process, actual native tray, compositor, receiving application,
production logging measurement, native latency or memory-growth result is
claimed. The original publication/root relationship and all native receiving
limitations remain explicit. No production or registered test code was changed.
