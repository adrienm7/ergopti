# Contradictory follow-up: Windows repeat timing

Audited commit: `b17e47ed3bb92c106703d3e3482b3c2973f5bc1e`.

**No additional confirmed production defect.** There is a concrete cross-platform timing difference to document, with no explicit cross-platform policy located that makes either behavior the intended default. The Windows conclusions below derive from exact source; no AHK, elapsed timer, editor delivery or performance experiment was executed. The Python program authenticates eight files and checks thirteen lexical relationships; it does not simulate AutoHotkey.

## Public Windows timing verdict

Set `hotstrings.idle_reset_seconds=0`, enable the repeat fallback, keep one stable admitted editable target and do not pause/rebuild the driver. Ensure no registered, personal or programmable rule claims the suffix. Typing `po`, waiting one or two seconds and pressing the configured magic key remains eligible to produce `poo` on Windows. These are source-derived predictions, not measured native results.

| Windows source scenario                                                                     | Source-established verdict                                                                                                                                            |
| ------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `po`, 1 s pause, magic; idle disabled, no competing suffix                                  | Repeat remains eligible.                                                                                                                                              |
| `po`, 2 s pause, magic; same controls                                                       | Repeat remains eligible. There is no repeat-specific two-second deadline.                                                                                             |
| Any longer pause; idle disabled and otherwise unchanged ownership                           | No repeat-specific elapsed-time check exists. Focus/pause/rebuild/suppression and matcher context can still refuse independently.                                     |
| A registry mapping `po<magic>` matches but its positive activation delay has expired        | The registry winner blocks repeat. Its later dispatch time preflight refuses; the physical path does not retry the fallback.                                          |
| The registry has no winner, but a programmable suffix exists whose activation delay expired | Live `UserHotstringsOnChar` refuses during its own preflight before claiming the key. The physical hook then permits repeat fallback if all its ordinary guards pass. |
| Idle reset enabled and the pause reaches that configured threshold                          | Ordinary buffer reset can remove the repeat's predecessor. This is separate from a repeat activation delay; the default idle interval is three seconds.               |

The public chain is `_OnPrefixChar` -> `HSE_FeedChar` -> raw registry `HSE_FindMatchAtEnd` -> personal fallback -> programmable claim -> `HSE_TryRepeatKey` -> `HSE_DispatchMatch` -> `_HSE_PrepareDispatchDecision`. The repeat transient Spec contains neither `TimeActivationSeconds` nor `PrevCharKey`. Its canonical preflight initializes time fields to zero and only enters the time gate when the Spec explicitly carries a positive `TimeActivationSeconds`. A zero `RemainingMs` on this ungated decision is not a dispatch refusal.

The registry matcher performs shape, case, boundary, priority and registry-availability checks, not the dispatch activation-time test. A nonempty raw winner prevents all lower fallback attempts. If its later `_HSE_PrepareDispatchDecision` returns empty due to expired timing, `_OnPrefixChar` records `dispatch_refused`, preserves the typed characters and returns; it does not revisit repeat. This protects a requested higher-precedence expansion from silently becoming a different doubling. It is not evidence that Windows filters expired registered mappings before fallback.

## Canonical oracle and programmable nuance

`HSE_PreviewNextDecision` uses the same transient repeat Spec and same canonical preflight. With no higher candidate, its internal decision is also ungated. `_PrefixDecisionIsDoubling` intentionally withholds that decision from the user bubble, as already documented in the completed repeat audit.

The prospective oracle first asks `HSE_FeedChar`, then personal/programmable-preview/repeat fallbacks only while its chosen match is empty, and only afterward runs `_HSE_PrepareDispatchDecision`. Thus an expired registered mapping blocks its fallback exactly as on the live path.

A narrower internal asymmetry exists for a valid enabled programmable suffix with a static preview: `UserHotstringsPreviewSpec` returns a timed Spec before applying its gate, whereas live `UserHotstringsOnChar` checks that gate before claiming the key. When both lookup paths identify the suffix but its delay has expired, the oracle can select it, fail preflight and report no decision; the live key can instead reach the repeat fallback. This does not establish a wrong visible promise: repeat bubbles are deliberately withheld, and a timed-out programmable row is also absent. It is retained as a source-qualified oracle-completeness caveat, not automatically promoted into a new G5 finding or TODO. A future genuine AHK replay can directly compare both decisions before deciding whether the internal oracle contract requires a separate change.

## Intent evidence and OS comparison

The routed memory `project-the-windows-time-gate-times-every-observed-key` explicitly describes the Windows doubling as **“ungated”**, while distinguishing time-gated TOML registrations. This corroborates that the lack of fallback timing is known behavior. It is an implementation observation; it does not declare that macOS should behave the same way or that its own gate is a bug.

The shared `repeat_key_enabled` manifest leaf declares an enable switch, no repeat-specific activation-time parameter. The shared repeat corpus checks pure buffer resolution and has no public elapsed-event cases. Neither establishes a uniform elapsed-time policy.

macOS's actual public `keymap/init.lua` has a separate condition before calling the same repeat emitter at both public fallback sites:

```lua
local star_allowed = CoreState.DELAYS.STAR_TRIGGER * complex_mult
if (star_allowed == 0 or _tc_dt <= star_allowed)
    and Expander.try_repeat_feature(chars, ...) then
```

Therefore a direct call to the macOS repeat emitter alone cannot certify parity of public timing with Windows. The effective resolved star delay, complex-key multiplier and last-key elapsed value must be retained when describing the Mac result; a local `STAR_TRIGGER` initializer by itself is not proof of its effective runtime setting. The separate macOS explicit-star path can bypass mapping delay yet still time-gate the lower repeat fallback. Linux's public elapsed behavior was reviewed by the Linux/root owners and is not re-certified by this Windows note.

Recommended matrix wording: **Windows repetition: available, no repeat-specific activation deadline; subject to ordinary context/idle/lifecycle gates. macOS repetition: available, public fallback additionally follows its effective star-trigger delay/complex-key gate.** Classify the difference as observed with intent unestablished. Do not call it an intentional OS restriction, a missing feature, or a new defect solely from the difference.

## Evidence and limits

Run `python3 source-contract.py <repo-root>` and inspect `source-contract.txt`. The program binds the real caller, transient Spec, matcher, canonical gate, oracle, programmable live/preview owners, shared switch and historical policy text to the pinned source. Comments are removed from relevant executable source slices for lexical relationship checks; those checks remain source evidence, not execution. Scope includes competing registered/programmable winner behavior, idle disabled/enabled, canonical oracle and public Mac gate comparison. No prior completed artifact was altered and no production or registered test was edited.
