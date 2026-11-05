# macOS one-shot Shift audit

Source: `9c565c88c9a1366a2e9b18c1b9d2868509510975`. Audit date: 2026-11-05. Scope is the single-use Shift feature, its public Keymap route, and interactions with settings and adjacent owners. No production changes were made.

## Confirmed findings

### OSM-001 — Caps Lock plus held Shift spends the mode without applying its title result

The shipped Ergopti Plus layout maps keycode 0 to `a`, `A`, `A`, `a` for no modifier, Caps Lock, Shift, Caps Lock plus Shift. With Caps Lock and physical Shift already held, the first character is lowercase `a`. The shared policy requests title `A`. The adapter checks whether Shift **alone** can produce that title, then applies Shift by ORing it into the **original** flags. Those flags already contain both Caps Lock and Shift; translation remains lowercase. The one-shot deadline is spent.

`public-probe.lua` executes the original public Keymap callback, original adapter, original state owner and original shared policy. Its recorded translator reads the actual shipped XML through the original shared parser. The four controls give `A/A/A/a`, and the last case retains raw flags 196608 and emits no replacement. This proves the logical event transformation and lost title result under that recorded native port; it does not prove a physical application received lowercase on macOS. The relevant source is `adapters/one_shot_shift.lua:58-63,109-121`. The same raw lock state may arise while CapsWord holds Caps Lock; the probe does not claim native CapsWord activation itself.

Recommendation: validate the translation using the complete prospective flags that will actually be applied. If it does not equal the requested title, use the existing serialized title output path. Preserve physical flag/release ownership; do not blindly strip Caps Lock from the user's held state.

### OSM-002 — Positive fractional programmatic timeout commits zero and makes public arming raise

`Remap.set_sticky_timeout` checks positivity before flooring. Actual Remap transaction execution accepts 0.1 or 0.9 ms, publishes a live getter of zero, and sends zero to its acknowledged persistence port. `Keymap.arm_one_shot_shift` rejects zero with `invalid one-shot Shift timeout`. This is an internal public API/configuration invariant failure, not the ordinary menu input path: the menu floors before calling the setter, and its resulting zero is rejected.

`config-probe.lua` executes the original Remap setter and transaction owner using the registered transaction fixture with remapping initially disabled. Its persistence port acknowledges and records the exact payload; real filesystem persistence is not asserted. `public-probe.lua` independently executes actual Keymap arming with that same invalid value. These are two original-owner executions linked by the real getter/setter source contract, not one simultaneous full application instance. Inputs 0, 1, 2.5 and 2000 are controls. No native application failure is claimed.

Recommendation: validate after flooring, or reject non-integer milliseconds before mutation. Validate numeric timing leaves when loading user configuration as well.

## Coverage and deliberate differences

- `sticky_shift` is a catalogue name whose action directly calls public Keymap one-shot arming. It does not use the generic sticky-modifier owner. Compound sticky actions use that separate owner and have different repeat-invocation semantics.
- Native F20/control-sentinel arming reaches the Keymap listener; stale reserved controls are handled before ordinary stale physical transformation. The registered lifecycle cases exercise original callback ownership, start failures, outage repair, stale input and paused/admission-closed consumed release debt. No native Karabiner delivery claim follows.
- The old three-key roll problem is **not repeated as a finding**: actual current public callbacks produce `Abc` for overlapping fresh `a,b,c` downs. Repeat/release gives `AAa`, retaining Shift only through the first original key's repeat lifetime.
- Editing controls Backspace, Enter, Tab and Escape spend the mode. Arrow and function-key controls retain it. The state suite additionally covers policy controls and expiry boundaries. Public Cmd shortcut processing retains activation; a subsequent `a` becomes `A`.
- Reinvocation refreshes the deadline rather than toggling the mode. Public probe advances the recorded monotonic clock, refreshes, and obtains `A`; an expired activation produces `a`. The timeout is read when arming, not continuously re-read.
- Special punctuation/space cases use shared policy output: `.→ :`, `,→ ;`, `=→º`, `'→ ?`, `space→-`; each consumes the original press and leaves the following letter unshifted. Live magic policy and Unicode fallback are covered by the original registered state/adapter suites. The public probe's magic-source geometry port is explicitly disabled, so it does not certify a native physical-magic route.
- Public pause disarms and refuses new activation, then resume leaves the next letter lowercase. Registered adapter tests cover refusal, rollback, provisional handoff, unrelated flags, repeat/release and missed releases. Registered lifecycle tests cover callbacks around stale events and ownership. Their declared ports are not native delivery certification.
- Complete stop resets the owner and tap-outage recovery resets it. Disarm preserves absorbed release debt; the distinction between deactivation and full ownership reset is intentional and avoids unmatched releases.
- macOS uses a user-configurable timeout; the parent shared review compares that to other OS configuration policies. This audit does not invent a common fixed timeout contract.

## Unresolved cross-owner candidate

A one-shot punctuation replacement calls `SyntheticInput.emit_key_strokes` directly and does not call `infra.capsword_output.report`. The latter explicitly exists because returned events skip preceding taps. The serializer's collector branch builds returned events and `leave_callback` hands them off. The CapsWord watcher tests the original text and also installs a driver-output observer. For a space-only termination policy, physical `.` can retain CapsWord while generated ` :` should end it.

This is a concrete missing relay source path, but this audit's emission port does not run the serializer plus watcher and cannot establish native tap ordering. It is **not counted as a third confirmed failure**. A combined original-owner replay or native ordered-tap test is needed before claiming observed CapsWord persistence. Windows OneShotShift does not itself cancel CapsWord; a nearby cancellation belongs to the separate ToggleCapsLock function, so no cancellation parity claim is made here.

## Verification and limits

Six registered suites independently execute 106 cases with zero failures: state 7, adapter 9, public lifecycle 50, shared timeout 1, gesture actions 33, pause owners 6. The mechanical false-green scanner reports baseline 0 versus 0; semantic ownership and port review remains necessary.

After the last new root, `replay.py` ran two bounded final sweeps: public callback probe, real Remap setter probe, and all six registered modules in fresh processes and fresh TMPDIRs. Both sweeps passed. The public probe executes 22 scenarios; it intentionally asserts the dated failing Caps+Shift result to preserve a reproducible audit receipt, not a green regression test of corrected behavior.

The public fixture prefix is extracted from an existing registered test solely to supply native lifecycle ports. Production bodies are required from the repository unchanged. Translation is an explicit stateless projection of the shipped layout's first four modifier maps and `state=none` action outputs, using the original parser. It does not emulate Quartz dead-key state, IME, Option/Command modifier-map selection, secure input, focus, or application receiving. Other Keymap services such as LLMBridge, expanders and text sender are non-target fixture ports. Their behavior is not certified by these passes. No macOS host, physical receiving application, latency, memory or G4 end-to-end result was available.
