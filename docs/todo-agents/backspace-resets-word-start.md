<!-- docs/todo-agents/backspace-resets-word-start.md -->

# Backspace and the word start (October 21, 2026)

The maintainer's report: after typing a letter or a word and deleting it, a
word-start hotstring (`c★` -> « c’est », `j★` -> « j’ai », `ct★` -> « c’était »)
was neither offered nor expanded; he had to type a space first. Final
specification: no setting, fixed behaviour on the three drivers.

## What the evidence shows

- **Proven (typing ledger of 2026-10-21, key classes only):** in Windows
  Terminal running Claude Code, Enter submitted the prompt, 45 s later `c★`
  expanded, the six following Backspaces erased the five characters of
  « c’est » and one more, then `C★` (capital) at 21:21:06 offered nothing. The
  same `c` had been offered three times in the minute before, each time after
  exactly as many Backspaces as typed letters. The capitalized path itself
  works: the only other capital `C` of the day was offered. The engine read
  the sixth Backspace as deleting unseen text (`HSE_StartIsWordBoundary :=
false`), while the prompt was empty (the Enter at 21:20:08 had submitted it
  and nothing else was typed before `c★`), so it deleted nothing. The new Windows test
  `terminal ledger replay of 2026-10-21` replays that sequence and fails on
  the previous engine.
- **Code defects found on the way (each with a test that fails on the previous
  code):** a Backspace that erases the whole buffer after an unknown start
  never restored the word start; an idle reset applied on the Backspace key
  itself forgot the word the Backspace was deleting (Windows, macOS); a
  terminal Enter's newline entered the Windows buffer, so a pause then reset it
  to an unknown edge; Ctrl+Backspace reset to an unknown position.
- **Hypothesis, not proven:** the earlier failures he remembers in other
  places (« J’ai », « C’était ») were the same over-long erase or a pause
  before deleting. The ledger window 20:45-21:40 holds no other `c`/`j`
  sequence right after Backspaces.

## The rules (all three drivers)

1. The Backspace that erases the last character typed since the buffer
   started puts the caret back at a word start. A correction that leaves
   characters keeps the word. A Backspace past the buffer start makes the
   start unknown,
2. except on a known empty line: a bare Enter in a terminal, Ctrl+A outside a
   terminal (Cmd+A on macOS), Ctrl+L in a browser (Cmd+L). There a Backspace
   deletes nothing and the word start stands.
3. A pause before a Backspace keeps the word it edits.
4. Ctrl+Backspace (Option+Backspace on macOS) starts a word; Alt+Backspace,
   Cmd+Backspace and Super+Backspace keep the unknown start.

Owners: Windows `HSE_FeedBackspace`, `HSE_FeedReset(…, AtLineStart)`,
`_PrefixRestoreIdleForgottenWord`, `_PrefixWordDeleteChordHeld`; Linux the
shared `hotstring_engine` (`backspace`, `reset(at_boundary, at_line_start)`,
`reset_after_pause`) and `modules/hotstrings/word_reset.lua`; macOS
`modules/keymap/init.lua` (`start_is_line_start`). The memory entry is
`project-backspace-word-start` in `docs/memory/text-input-and-config.md`.

## Tests

- Windows: `tests/unit/modules/hotstrings/engine/test_hotstring_backspace_word_start.ahk`
  (`--only "(bs-word-start)"`): field, address bar, Ctrl+A, three AltGr layout
  families, a remap's Backspace, Windows Terminal full dispatch with the paced
  terminal owner, the ledger replay; plus the Ctrl+Backspace case of
  `test_hotstring_event_word_reset.ahk`.
- Linux: `--only "bs-word-start"` in `test_shared_hotstring_engine.lua` and
  `test_word_reset_events.lua` (real hook, real loader).
- macOS: `--only "bs-word-start"` in `test_arrow_shortcut_word_reset.lua`
  (real event tap).

## Known limits

- A browser's inline autocompletion: the first Backspace deletes the
  suggested completion, not a typed letter, so the buffer runs one character
  ahead and a later word-start hotstring can fire after a remaining letter.
  No driver reads the field's text there.
- Linux sees no modifiers on a typed newline, so Shift+Enter in a terminal TUI
  is also read as submitting the line.

## Physical checks for the maintainer

Windows PC (now), after reloading the driver from the working tree:

1. Windows Terminal, Claude Code prompt: press Enter on an empty prompt, type
   `ab`, Backspace twice, `c`: the bubble offers « c’est »; `★` expands it.
2. Same, then hold Backspace until the prompt is empty and press it once more,
   then `C★`: « C’est ». Repeat with `J★` (« J’ai ») and `Ct★` (« C’était »).
3. Same prompt: `ab`, wait 5 s, Backspace twice, `c★`: expands.
4. Correction: `ab`, Backspace once, `c★`: nothing (it is « ac★ » mid-word).
5. Notepad or Word: type a word, Ctrl+Backspace, `c★`: expands.
6. Firefox or Chrome: Ctrl+L, Backspace, `c★`: expands in the address bar;
   also type `ab`, Backspace twice, `c★`.
7. AZERTY-style AltGr layout and the Ergopti (Kana-style) layout: AltGr+Backspace
   behaves as a plain Backspace, Ctrl+Backspace as above.

Mac (later): Terminal or iTerm2, Return, `ab`, Backspace three times, `c★`;
TextEdit Option+Backspace then `c★`; Safari Cmd+L, Backspace, `c★`.

Linux (later): GNOME Terminal or kitty, Enter, `ab`, Backspace three times,
`c★`; gedit Ctrl+Backspace then `c★`; Firefox Ctrl+L, Backspace, `c★`.

## State

Pushed to dev: 0bac8b672e (Windows), 969f49998a (Linux), d01c21e0f9 (macOS),
9376fdf57f (memory), 273962f885 (updater source reseal: run_all.ahk is one of
the 21 sealed sources), afc704b454 (macOS fail-fast loader stubs). The manifest
comments describing the rules rode in 61ab0fb351 with another agent's change.

Hosted full runs: 39672299252 at 9376fdf57f (reds: the seal and the fail-fast
stubs, both fixed above), then 39678425941 at afc704b454: Windows and Linux
green; macOS core red only on the `(live-tap-hold-transition)` lease tests that
came with the tap-hold action picker (61ab0fb351), reproduced locally and not
part of this work; the Shared UI E2E red was a Playwright browser download
failure. Locally: the AHK `hotstrings-shortcuts` group 1541/1541, the `meta`
group 2940/2941 (the one red counts the private runner copy in `tests/`), the
five boot checks and the macOS E2E 73/73.
