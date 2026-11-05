# CapsWord parity: public activation, output and automatic termination

Audited source: `f2a7dba5fc580aad61e6a0ed16ede84406aed2b0`, November 5, 2026.

Four reviewers worked on the same bounded module in separate pinned worktrees:
Windows, macOS, Linux and the shared policy/declarations. This pass follows the
public action through its accepted producer, active session, output, settings,
clock, pointer events and retirement. It does not implement engine fixes.

The initial scopes contain **159 qualified coverage rows and nine new findings**:
Windows 37/two, macOS 42/three, Linux 55/two and shared 25/two. Coverage rows are
reviewed aspects or retained observations, not independent native experiments.
A subsequent synthetic-key countercheck extends the **existing WRSL-001 root**
with a CapsWord consumer; it is not counted as a tenth new architectural root.
The supplemental12 rows bring the canonical register to171; its ten finding
entries comprise nine new findings and one known-root extension.
The original role submissions, additional countercheck and root adjudication
remain separately identifiable in the archive and generated index.

## Exact new findings

All examples below name logical state, emitted requests or recorded output.
Actual letters received by a desktop application were not measured. Windows
findings are executable-source deductions; no AutoHotkey code ran here.

| Finding             | Accepted configuration and action                                                                                                                                                                                                                                                              | Observed discrepancy                                                                                                                                                                                                         | Evidence boundary                                                                                                                                                                                                                                                 |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **CWW-001**, medium | Idle0, pointer exits off, only Tab checked. Bind physical Tab to Backspace, without hold; empty AI tooltip and navigation off. Activate CapsWord independently, type two letters, tap Tab. The opposite control binds CapsLock to Enter in an empty hotstring context with only Enter checked. | The generic tap dispatcher tests the physical carrier before its configured callback: Tab→Backspace ends despite no Tab output; CapsLock→Enter can emit Enter without ending.                                                | Source-only public admission/action/send chain. The ambiguous competing physical Space hotkey is explicitly excluded from the confirmed reproduction.                                                                                                             |
| **CWW-002**, medium | Idle0, no delimiters/pointer exits; isolated AltGr tap configured as `caps_word`, with Shift hold. Make two accepted short taps.                                                                                                                                                               | AltGr unconditionally clears CapsWord before invoking its configured toggle. The second tap therefore turns it back on instead of toggling off.                                                                              | Source-derived accepted hold/tap and prior-key-self branch, real action resolver and state owner; no physical AltGr trace.                                                                                                                                        |
| **CWM-001**, medium | Turn pointer exits off before activation so menu traversal preserves the session. Activate with idle0; choose1s in the real menu callback, type another letter, advance the controlled clock beyond1s. Also test10→1.                                                                          | New policy and saved/menu state are current, but0→1 creates no expiry timer;10→1 retains the old due callback. Delimiter changes and opposite timeout changes distinguish the missing re-arm.                                | Actual submenu, settings and watcher with recorded scheduler ports. No wall-clock latency or native timer precision claim.                                                                                                                                        |
| **CWM-002**, medium | Idle0. Inactive pointer movement at0ms, activate at10ms, then one checked click/gesture/scroll at50ms.                                                                                                                                                                                         | Inactive traffic stamped the global100ms pointer gate. The new session's first qualifying exit is discarded. No-prior-pointer and100ms boundary controls do clear.                                                           | Actual watcher, variable owner and control sentinel, with controlled native events/clock.                                                                                                                                                                         |
| **CWM-003**, medium | Old pointer clear publishes native variable0, but its exit callback remains queued. A permitted fresh activation publishes1; a checked delimiter arrives before the old callback.                                                                                                              | The older operation's global pending flag rejects the newer delimiter. Its eventual completion correctly preserves the new activation but never replays the lost event.                                                      | Actual serialized writer/watcher/sentinel; native publication and exit callback are separate recorded ports. This does not assume a native reactivation while the engine variable is still1.                                                                      |
| **CWL-001**, low    | Idle0, gesture exit off, pointer-motion exit on. An accepted absolute device reports contact, initial coordinates, then changed ABS_X/Y and closing frames.                                                                                                                                    | Original Hook dispatch publishes no motion for EV_ABS; the session stays active. The relative-mouse control publishes motion and ends it.                                                                                    | Actual original dispatch and Manager over recorded syscall/callback ports; device selection uses a real-format synthetic proc block. Main forwarding is source-only; no physical reader/compositor ran.                                                           |
| **CWL-002**, medium | Disable all pointer exits before activation. In original menu callbacks, uncheck Space, or enable initially disabled left-click. Rebuild the menu and supply the next event.                                                                                                                   | Saved bytes/cache/checkboxes change, but active Manager still holds its previous policy object. The next Space still ends; the newly checked click does not. New-session controls use the new values.                        | Actual original submenu closure, renderer, settings writer, Hook and Manager. This violates the Linux menu's written next-event contract; its snapshot ownership comment makes the intended lifetime a decision to align, not a permanent OS exclusion to invent. |
| **CWS-001**, low    | Manually configure accepted idle0.0001s; compare0,0.00049,0.0005 and0.001. Ordinary menu presets are unaffected.                                                                                                                                                                               | Both ports round0.1ms to0. Lua retains enabled numeric0 and can expire immediately; AHK treats0 as disabled.                                                                                                                 | Actual Lua policy/owner controls; AHK arithmetic/admission source only. No sub-millisecond hardware timing measurement.                                                                                                                                           |
| **CWS-002**, low    | Configure magic key§ and check the real CapsWord star-labelled menu row.                                                                                                                                                                                                                       | macOS/Linux can display§ while the active policy reacts to★ instead. Lua's captured character also depends on loading the policy before/after catalogue mutation; Linux's normal path does not use that same mutation route. | Actual shared policy and real Lua menu/settings/watcher or Manager paths. The required consistency is between caption and effect; choosing literal-star versus dynamic magic remains a separate policy decision.                                                  |

Canonical [findings.json](findings.json) preserves submitted IDs, source basis,
confidence, guarantees or named properties, exact regression direction and
current archive evidence hashes. Original role reports remain accessible:
[Windows](windows/report.md), [macOS](macos/report.md),
[Linux](linux/report.md), [shared](shared/report.md).

## Existing root extended by a further countercheck

The synthetic-key followup is retained separately in
[linux-synthetic-followup](linux-synthetic-followup/report.md). It observes real
keyboard-slot configuration and consumption, acknowledged catalogue Enter/Tab
emission, and the CapsWord consumer. Pointer exits are disabled before activation;
idle is zero and only the matching delimiter is selected.

A configured Ctrl+A slot can consume its carrier and emit one accepted Enter or
Tab through the actual catalogue/emitter/writer without ending CapsWord. Literal
injector newline/tab does notify the existing CapsWord observer and ends it.
The missing semantic-publication connector overlaps the previously recorded
[WRSL-001](../2026-11-05-word-reset/linux/report.md); this pass adds a different
consumer and regression requirement instead of counting another independent
connector root. The existing TODO is extended accordingly.

An important rejected generalization is retained: ordinary tap actions named
`enter`/`tab` use `KEY_TAPS` and return native rows through Hook semantic dispatch.
They do **not** take this generic catalogue callback, and their positive controls
end CapsWord. A claim that every synthetic Enter is broken would be false.

## Intentional differences, observed variants and unresolved policy

- **Action names:** shared declarations explicitly map Windows/Linux
  `caps_word` to macOS `capsword`. Different IDs do not mean the feature is absent.
  Repeated catalogue invocation toggles on Windows/Linux but requests active on
  macOS; the common re-invocation policy is not established. The separate native
  Karabiner CapsLock graph must not be equated with the catalogue handler.
- **Settings lifetime:** Windows menu and Store explicitly apply new values at
  the next activation. macOS's owner/menu deliberately apply current values live.
  Linux combines an active snapshot with a menu promise of next-event application;
  the inconsistency is recorded without treating either comment as a universal
  product decision. External hand-edit refresh is a different path.
- **Gesture support:** Windows deliberately excludes the gesture pointer kind,
  with `platform_reason.caps_word_gestures_stay_with_windows`; the system retains
  those gestures and can expose only resulting scrolling. All other shared
  pointer declarations and requirements remain explicit. This is a declared
  constraint, not a negative search result.
- **Fixed macOS exits:** actual generation retains Escape/navigation/Delete/F-key
  exits and removes settings-owned Space/Enter/Tab exits. Root matched controls
  execute the actual Linux Hook/Manager with idle0 and no delimiters: Escape and
  Left retain the session. The local generated construction is explicit; a
  common permanent exception policy is not established.
- **CapsLock ownership:** Windows separates genuine lock intent; Linux rides and
  preserves an existing lock. macOS requests/toggle emissions do not establish
  initial-lock preservation or native quit/reload restoration. These remain
  qualified policy/receiving gaps, not invented permanent exclusions.
- **Activity and control identity:** Windows's observed key-down subscription
  includes modifiers. macOS's watcher sees keyDown, not flagsChanged/keyUp.
  Linux's corrected-symbol followup distinguishes real modifier-role dispatch
  from arrow controls. Shared wording does not settle a universal modifier rule.
  CR/LF/Tab, ETX, modified and keypad Enter remain distinct native payloads.
- **Numeric limits:** actual shared Lua accepts finite1e308 seconds and overflows
  milliseconds to infinity. Native timer admission was not exercised; this is a
  qualified boundary observation, not another crash or resource finding.

The [generated matrix](capabilities.md) separates availability, evidence basis,
explicit local intent, native constraints, observed defects and unknown intent.
It does not infer that a whole capability is absent from a missing setting row.

## Independent validation and custody

The initial four roles authenticate154 overlapping claims over127 distinct named
files. `check_sources.py` compares both pinned Git bytes and current files;
it refuses drift rather than silently re-hashing reviewed evidence. The source
receipt explicitly excludes a claim of all transitive dependency coverage.
The23 supplemental claims overlap14 prior paths and add nine: the final source
check authenticates177 role claims over136 distinct named paths. They do not
establish transitive completeness.

Root replays include all five macOS decisive programs, the actual Linux owner
under Lua5.4/LuaJIT, shared policy/magic programs under both runtimes, declaration
projection, Windows/Linux/shared source programs, and every selected registered
module. The initial valid root batch has50 successful processes and independently
re-derives148 macOS cases and88 Linux cases per runtime. Repeated registered
cases are not additional unique coverage. Supplemental and post-integration
receipts record their own actual process set in `validation/`. The complete
parent replay including the supplemental source program and both runtimes has53
successful processes; the324 registered cases are repetitions of existing
coverage, not324 new findings or native receiving cases.

The first root batch had one invocation error: Linux's source CLI was missing its
required `--output`. Its unsuccessful receipt is retained in
`validation/root-initial-replay/`; the corrected full invocation passes. That
error is not an observed driver failure.

An initial Linux parallel fixture failure is also retained. The original owner
program's SHA is unchanged across failure and subsequent private-TMPDIR passes.
Only the instrumented standalone diagnostic has a retained log, so no
byte-identical standalone success is claimed. A temporary-name collision remains
suspected, not a reconstructed or repaired production cause.

The initial Linux native port supplied no modifier keysyms: its Ctrl+Tab row
cannot establish the actual modified-control route, and its Shift row did not
qualify modifier-role admission. Followup ports supply the real Control_L and
Shift_L symbols and re-test those routes. Initial observations remain historical;
they are not relabelled as native modifier proof. Canonical qualifiers and the
supplemental results distinguish the two fixtures.

Worker hash claims retain their exact original bytes. Repository formatting
changes are documented in [format-provenance.json](validation/format-provenance.json).
The Linux standalone wording correction is explicitly editorial, with its
submitted report preserved; it is not claimed semantically equivalent to the
corrected archive. See [custody notes](validation/custody-notes.md) and the
[custody summary](validation/custody-summary.json).

## Scope limits and replay

No native AutoHotkey execution, physical evdev reader, actual Karabiner key
receiving, desktop CapsLock restoration or application consumption is certified.
The actual Lua owners run over recorded native ports, with the limitations above.
No G4 latency or long-duration memory-growth measurement was made. Deterministic
retirement controls are not a memory-growth experiment.

Both final bounded passes for each original role found no further root in their
chosen scope. The later synthetic countercheck demonstrates why that does not
certify whole-repository exhaustiveness. Its own final passes are separately
retained. Hypotheses and native gaps do not inflate confirmed-root counts.

With the documented Lua/Node toolchain on PATH:

```sh
python3 check_sources.py /path/to/ergopti --output /tmp/capsword-sources.json
python3 replay.py /path/to/ergopti --output /tmp/capsword-replay
python3 project.py --repo-root /path/to/ergopti --check
python3 check_project.py /path/to/ergopti
```

`owner.json` is root-adjudicated input; `project.py` generates the four dated
projections. This custom composite schema accepts all-zero finding scopes and
rejects22 malformed controls. It is not the legacy AHK/HS report-validator
envelope, native parity certification or automatic discovery of undeclared
features. The site's live configuration inventory already declares the CapsWord
parameters; a checked declaration does not certify these runtime edge cases.
