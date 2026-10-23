<!-- docs/todo-agents/windows-input-hooks-items-49-50.md -->

# Windows input hooks: items 49 (hook order) and 50 (SendEvent against SendInput)

Status on 2026-10-23. Two Debug menu rows now measure these questions on the
real machine. Nothing here changes a default; the native DLL
(`ergopti_nav_owner.dll`) and its manifest are NOT regenerated (this checkout
has no MSVC generator), so every native-contract change listed under "Left" waits
for a build on a machine that has one.

## The two checks

Both rows are in the shared Debug menu (`menu.debug_menu` in
`_shared/modules/features/manifest.toml`), declared for `ahk` only with the
reason `platform_reason.input_probe_is_autohotkey_specific` (no other driver has
SendInput or an AutoHotkey hook). Code: `windows/infra/input_probe.ahk`; pure
cores and menu declaration are pinned by
`windows/tests/unit/infra/input_probe/test_input_probe.ahk`.

Each click asks for a confirmation, opens a small window the check owns, types
only into it, shows pass or fail with one line per step (all text through i18n,
21 locales) and writes the evidence to today's log under the tag `InputProbe`.
The records hold counts, timings and enumerated states; no typed text. A check
refuses to start (and says why) while the driver is paused, a modifier key or
Caps Lock is on, another check runs, or its window cannot take the focus.

### "Measure SendEvent vs SendInput" (item 50)

For each scenario and each primitive: 1 unmeasured warm-up, then 8 repetitions.
Scenarios mirror the driver's real shapes: `expansion` (5 Backspaces then
`{Text}` replacement, under Critical like the hotstring burst), `paste` (clipboard
set under the clipboard owner, then Ctrl+V; the user's clipboard is restored,
skipped when the clipboard is busy or holds an image), `prediction` (the
TextSender funnel `_TextSenderSendInput` with its `_AHK_SendInput` primitive
swapped), `rival` (the burst while a timer sends a rival `#` as soon as the
thread is interruptible).

Record lines:

```
send_compare context ahk=... os=... key_delay=... send_level=... reps=8
send_compare scenario=expansion mode=SendInput n=8 exact=8 lost=0 interleaved=0 garbled=0 timeout=0 return_med_us=... settle_med_us=... settle_p95_us=... settle_max_us=...
```

`settle` is the time until the target holds the exact text; `return` is the time
the Send call took. `lost`/`garbled`/`timeout` must be 0 for a pass; `rival` is
evidence only.

First measurement, standalone host on the maintainer's PC with the resident
driver running (so SendInput falls back to SendEvent, see below), SendKeyDelay 0:
expansion 152 ms (SendInput) against 262 ms (SendEvent), prediction 198 ms
against 386 ms, paste 16 ms against 9 ms; every repetition exact in both modes.
The rival key never interleaved under either primitive: a timer cannot interrupt
a Send, so an AutoHotkey-thread rival can only land after the burst. A genuine
OS-level interleave needs a second process (or a physical key): see the manual
list below.

### "Record keyboard hook order" (item 49)

A test low-level keyboard hook is installed on the main thread after the
driver's (so it is first in the chain, like `ergopti_nav_owner.dll` at boot),
with a hotkey on F24 (`*SC076`, no other use) whose job is to swallow the key.
Windows calls the newest hook first, so the test hook sees F24 only while it is
ahead of AutoHotkey's hook. Phases: `before` (SendEvent F24), `during_sendinput`
(a real SendInput of F24), `after` (SendEvent F24 again), `control` (test hook
reinstalled, SendEvent F24: must see the key, otherwise the method is unsound).

Reading the record:

```
hook_order before=test_first(seen=1,fired=1) during_sendinput(seen=1,fired=0) after=ahk_first(seen=0,fired=1) control=test_first(seen=1,fired=1) changed=yes rehook=yes conclusive=1
```

- `changed=yes rehook=yes`: SendInput removed and reinstalled AutoHotkey's hook,
  which moved it in front of a hook installed earlier. Confirms
  `project-ahk-sendinput-puts-its-hook-first`.
- `changed=no rehook=no`: `fired>=1` during SendInput means AutoHotkey's hook was
  never removed: SendInput fell back to SendEvent because another AutoHotkey
  keyboard hook runs (`SystemHasAnotherKeybdHook`). Nothing moved.
- `conclusive=0`: a phase without its hotkey firing, or a control that did not
  see the key. Resend the record; do not draw a conclusion.

Measured here from a standalone host while the resident driver ran:
`before=test_first after=test_first rehook=no` (the fallback case). The case
`rehook=yes` can only be produced by the check run INSIDE the driver when it is
the only AutoHotkey keyboard hook: that is the run the maintainer does from the
Debug menu.

Limit: the test hook stands for "a hook installed after AutoHotkey's". It does
not observe the native owner's own hook, whose order against AutoHotkey's can
only be deduced from the same Windows rule.

## Terminal capture consumers (read from the code, not measured)

What terminal capture does (`native/nav_event_owner/nav_event_owner.c`,
`NavCaptureTerminalEventLocked`, `NavBuildTerminalReplayBatchLocked`): while a
paced terminal output holds a capture, the native hook suppresses every
non-injected keyboard edge in a FIFO, then replays the accepted prefix with
`SendInput` using scan codes and `dwExtraInfo = ERGOPTI_NAV_TERMINAL_REPLAY_MARKER`
(`0x4552475054524D31`). Consequences for any AutoHotkey consumer, all from
AutoHotkey's documented rules plus `project-llm-automation-accepts`:

1. A replayed edge is injected and unmarked, so AutoHotkey ranks it at the highest
   level: every hotkey (`#InputLevel` 0 to 3) and every `I1` InputHook sees it.
2. It is not physical: `GetKeyState(.., "P")`, `A_TimeIdlePhysical`,
   `KS_GetPhysicalInputGeneration()` and anything built on them do not see it.
3. Its timing is the replay's, not the user's (tap and hold durations measured
   by `KeyWait` stretch by the capture's duration).
4. The native owner itself reclassifies the replay as physical for its own
   routing (`ERGOPTI_NAV_INJECTION_PHYSICAL`); AutoHotkey does not.

| Consumer                    | Entry in the code                                                                                                                                                                                                                              | State it trusts                                                                  | Exposure to a replayed edge (static reading)                                                                                                                                                                                                                                                                       | To verify on hardware                                                           |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------- |
| KLE (keylayout emulation)   | `modules/keymap/keylayout/keylayout_emulation.ahk`: one hotkey per emulated scan code at `I2` (`input_level`), Alt variants `I3` (`KLE_ALT_INPUT_LEVEL`); shift read with `GetKeyState("Shift", "P")` at line 725                              | Shift physical state at emit                                                     | Down and up fire (rule 1); a replayed Shift is not physical, so a held Shift replayed with the letter after it emits the unshifted layer. Repeat: a replayed repeat is an extra down.                                                                                                                              | letters with Shift held across a terminal expansion                             |
| Dead key                    | `modules/keymap/layout.ahk:778` `Hotkey(DeadSc, _DeadKeyDispatch..., "I2")` per registry entry                                                                                                                                                 | Pending-accent state in script memory (no physical read)                         | Fires on replay (rule 1); the pending accent is consumed by the replayed follower, so order is preserved only if the whole FIFO replays. A capture ended by pause or reload drops the FIFO with the accent pending.                                                                                                | accent key then letter typed during an expansion                                |
| Digit row                   | `modules/keymap/layout/layout_shift_caps.ahk:212-215` (`_DigitRowDown`, `... Up`, `_DigitShiftSend`) at `I2`; swap `layout.ahk:750`                                                                                                            | `DigitRowIsSwapped` per press, Shift in the hotkey name                          | Down and up both fire; the swap reads the foreground layout, not the key state, so it is unaffected by rule 2. Up edges replayed late can leave a digit held for the capture's duration.                                                                                                                           | digits typed during an expansion, release after it                              |
| Profile hotkeys (Ctrl+1..9) | `modules/llm` navigation (`_LLM_Menu_NavDigitRowKey`, VK_0..VK_9 with exact modifiers), native route first, `ui/menu/menu_llm/tab_accept.ahk` hotkeys at `#InputLevel 1`                                                                       | Exact modifier state, accepted Tab gated physical (`_LLM_Accept_BareTabRefusal`) | A replayed Ctrl is a logical modifier but not physical: chords match by modifier state, so they fire; anything gated on a physical Tab (prediction accept) refuses a replayed Tab.                                                                                                                                 | Ctrl+digit and Tab with a prediction shown while a terminal output is in flight |
| Tap-hold                    | `platform/remap/*.ahk` (`#InputLevel 2`, `ErgoptiPlus.ahk:1142-1146`, `1392-1453`), `KeyWait("SC00F"/"SC02A"/"SC038"/"SC11D", "T<ms>")` in tab, lshift_lctrl, lalt, rctrl; roll decision from `GetKeyState(.., "P")` (`tap_hold_roll.ahk:366`) | `KeyWait` default mode (to confirm), physical state for rolls                    | The tap/hold duration includes the time the edge waited in the FIFO, so a hold can be judged long. A replayed rolled key is not physical, so `TapHoldRollOtherKey` answers "not down". Owner change while held: the replayed Up of a key whose Down was suppressed is swallowed by design (`TapHoldPressIsOwned`). | tap of Space/Tab/AltGr during an expansion; roll over a tap-hold                |
| Combination                 | `infra/key_combinations.ahk` registering `SC01D & ...`, `SC138 & ...` chords at `I2` through `hotkey_registrar.ahk:831`; AltGr prefix arms on `IsRealAltGrPress` (`layout_altgr.ahk:132`, `KS_IsDown` physical)                                | Physical state of the prefix                                                     | The prefix press is replayed injected, so `IsRealAltGrPress` answers false: the suffixes stay ineligible and the AltGr chord types the plain key. Highest exposure of the seven.                                                                                                                                   | AltGr+letter, Shift+AltGr, LCtrl+RAlt AZERTY and Kana, during an expansion      |
| Script shortcuts            | `infra/script_altgr_hotkeys.ahk` (chords gated by `ScriptAltGrChordIsLive`, `GetKeyState("SC138","P")` at `layout_altgr.ahk:210/216`), slot output `SendEvent` Up at level 3 (`config_io.ahk:2102`)                                            | Physical AltGr                                                                   | Same as combinations for the AltGr chords; non-AltGr script chords fire on replay. A Down replayed without its Up would leave the latch the cleanup (`TapHoldReleaseUnlessOwned`) must undo.                                                                                                                       | script AltGr chord during an expansion                                          |

Down, repeat, up, owner change, pause and reload for every row share three
facts from the native code: the FIFO is drained in order or kept as debt
(`_LLM_NavEventOwnerHasTerminalDebt` blocks stop and reload until it settles,
`adapters/llm_nav_event_owner.ahk` 517-755); a pause suspends hotkeys but the
native hook keeps capturing and replaying (the native owner refuses plans while
paused, per `project-a-pause-guard-is-not-a-shutdown-debt`); a reload waits on
`terminal_debt`. What the table cannot say from reading is the user-visible
result per row: that needs the physical run below.

## Manual list for the maintainer's PC

1. Reload the driver from the working tree, open the tray, Debug.
2. Click "Record keyboard hook order". Confirm. Do not touch the keyboard for
   about 5 seconds. Paste the `InputProbe` lines of today's log
   (`%LOCALAPPDATA%\ergopti_plus\logs`, Debug > Open today's log file).
3. Click "Measure SendEvent vs SendInput", confirm, keep hands off for about 10
   seconds, paste the `InputProbe` lines.
4. Terminal capture rows (AltGr+letter, Shift+letter, digit, Tab with a
   prediction) while a paced terminal expansion runs in Windows Terminal: note
   which characters came out wrong and paste the `HSE`/`NavOwner` lines around
   them.

## Left (needs a build host or more hardware)

- Event-specific capture and replay, modifier ownership, source pin, authenticated
  event stream, non-hook handler conversion, chained and repeat semantics: native
  contract changes, `ergopti_nav_owner.dll` and its manifest through the official
  MSVC generator only; compare `docs/handovers/2026-10-12-dev-consolidation/`
  against the tree first.
- A second-process rival injector for a true OS-level interleave measurement.

## Hotstring output and chaining (2026-10-23, real-engine evidence)

The decision recorded for item 50 ("hotstring output must be able to trigger
another hotstring, `SendMode("Event")` exists for that") describes the retired
native `Hotstring()` engine. Read from the code and reproduced on the real
engine with `tests/unit/modules/hotstrings/engine/test_hotstring_output_is_final.ahk`
(`--interactive`: real `InputHook`, real keyboard, an owned window):

| Path                                             | Primitive and level                                                                          | Seen by the prefix watcher | Chain                                    |
| ------------------------------------------------ | -------------------------------------------------------------------------------------------- | -------------------------- | ---------------------------------------- |
| `HSE_DispatchMatch` atomic burst (GUI hosts)     | one `SendInput`, now at `TEXT_SENDER_SEND_LEVEL` (was the caller's level)                    | no (I1 ignores level 0)    | none; buffer set by `HSE_ApplyExpansion` |
| ellipsis and ê dead key raw callbacks            | `SendNewResult(..., Atomic)`: `SendInput` at level 0 (was `SendEvent` at the caller's level) | no                         | none                                     |
| terminal paced burst                             | `SendEvent` per key, `SendLevel(0)` (pacing needs `SetKeyDelay`)                             | no                         | none                                     |
| Notepad native edit                              | no key injected                                                                              | no                         | none                                     |
| `TextSender`                                     | `SendInput`, level 0                                                                         | no                         | none by design                           |
| layout and keylayout emulation (`SendNewResult`) | `SendEvent`, hotkey level 2                                                                  | yes                        | this is how a typed trigger completes    |

So the 2.7 times faster primitive was already the one in use for every
expansion, and nothing chained through it. The one real dependency on the
primitive was accidental: a burst sent at level 2 (the Space tap-hold thread)
re-entered the watcher whenever `SendInput` fell back to `SendEvent` (another
AutoHotkey keyboard hook, such as a user's own script), cascaded A, B, C and
left `HSE_Buffer` out of step with the screen. Reproduced before the fix
(`foo qbar qzz` instead of `foo qzy `), gone after.

Measured in a standalone host with no keyboard hook, so `SendInput` is real
(median of 14, `SetKeyDelay(0)`): expansion shape 117.2 ms (`SendEvent`) against
81.5 ms (`SendInput`), dead key 30.3 against 24.7 ms, ellipsis 39.7 against
41.8 ms (within the noise of the Edit repaint). The expansion path did not
change primitive, so its before and after are the same; only the two raw
callbacks moved, for consistency and level safety more than for speed.

`SendMode("Event")` is kept: it governs `Send`, `Click` and `MouseMove`, and
`SendInput` would remove the mouse hook around the gestures' `Click`. Its
comment now says so.

Left, decision for the maintainer: a deliberate cascade (an expansion that
completes a trigger) would be a new feature on every driver, not a primitive
choice. Measured blast radius on the shared data: 124 of 2786 replacements end
with their own trigger up to case (an infinite loop without a same-spec guard)
and 131 more end with another trigger. Do not add it without the shared corpus
vectors and the macOS and Linux engines.

Suspected separate defect, not touched: `_SpaceTap` (`platform/remap/space.ahk`)
emits the space with `TextPressKey("Space", "")`, which the declaration channel
treats as an "edit" payload (`HS_SyntheticPayloadKind("{Space}")`) and resets
both buffers; the engine is then fed the space on an empty buffer, so an
end-character trigger cannot complete from the Space tap-hold. Observed in the
real-engine harness (`before buf=[qzs]`, after the press `buf=[ ]`, no match).
Needs a look on a machine with the Space tap-hold on.
