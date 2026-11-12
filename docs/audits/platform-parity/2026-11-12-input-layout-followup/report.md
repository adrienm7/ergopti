# Input and layout: keyboard slots and held modifiers under the emulation

Audited source: `76da919b` (`claude/ergopti-todo-parity-audit`), against the
[input/layout campaign](../2026-11-11-input-layout/report.md). Date: November
12, 2026.

## Scope

The campaign's two open Linux rows:

- the keyboard shortcut slot still matched the system layout's key under
  an emulated layout (left open by ILL-001);
- a key passed under a modifier a tap-hold holds did not repeat (the second
  half of ILL-004).

The campaign's fixes, ILD-1, ILD-2 and its refuted list are not repeated.

## Fixed

| Id      | OS    | Sequence                                                                                    | Windows                                                                                                                  | Before                                                  | Regression                     |
| ------- | ----- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------- | ------------------------------ |
| ILX-001 | Linux | Ergopti emulated, a slot bound to Ctrl+Z, press Ctrl on the key that types « z » (QWERTY Q) | The slot is registered on the key that types its letter (`_KeyboardSlotLayoutVariant`, `KeyboardShortcutRunLayoutChord`) | The ctrl+q slot ran, or the chord went to the emulation | `ilx-001-slot-emulated-letter` |
| ILX-002 | Linux | Hold a tap-hold's modifier, then hold a key the keylayout leaves to the OS (F1)             | The key repeats under the held modifier, as with a real one                                                              | One press, no repeat                                    | `ilx-002-held-modifier-repeat` |

For ILX-001, the shared `keylayout_emulation.chord_char` names the character
a Ctrl, Alt or Win chord sends on a key, without changing the session.
`decide` now uses it, and still resets a pending dead key as before. The
Linux emulation exposes it as `chord_key`, and `consume_bound_chord` in
`ergopti_hotstrings.lua` offers the slots that letter. A key the emulation
leaves keeps its system letter. The regression compiles Main's own
`consume_bound_chord`.

## Not checked

The macOS emulation rewrites a chord's key code to the emulated letter's key
before passing the event on, so its Carbon `hs.hotkey` slots should already
see the emulated letter. This needs a Mac to confirm, as does native
receiving.
