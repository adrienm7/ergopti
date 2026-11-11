# Hotstring cascade and trigger arbitration: Windows, macOS, Linux and shared

Audited source: `2419b397` (`dev`); fixes rebased on `b42d3cb8b`. Date: November 11, 2026.

The register's next module (« Hotstring cascade and trigger arbitration »).
Windows (`windows/infra/hotstrings/hotstring_cascade.ahk`, `hotstring_match.ahk`,
`hotstring_dispatch.ahk`, `hotstring_inputhook.ahk`) is the read-only
reference; the shared engine (`_shared/lua/hotstring_engine/init.lua`,
`cascade.lua`), the Linux daemon (`linux/ergopti_hotstrings.lua`) and the macOS
keymap (`macos/modules/keymap/expander.lua`, `init.lua`) were compared with it,
link by link and candidate by candidate. Linux candidates were replayed
through the real shared engine under LuaJIT; macOS candidates through the real
registry and expander under Lua 5.4 with the harness of
`test_hotstring_cascade.lua`. No AutoHotkey, no Hammerspoon event tap and no
evdev/uinput receiving was executed: these are source and engine
counterexamples. Two bounded sub-audits ran alongside, read-only, on the
Backspace undo (decision of 2026-11-06) and on dynamic and personal
hotstrings since the 2026-11-04 module audit; their candidates were reopened
at the cited lines before being filed here, and every fix below was replayed
red then green.

## Source census reconciliation

`tools/audit/source-areas.py --ref HEAD` gives 377 areas against the 363 of the
last pinned census (`2026-11-05-native-ui/source-areas.json`): 14 new areas
(the 12 of the tap-hold campaign plus `_shared/ui/layout_editor` and Linux
`desktop_focus`), none removed, 212 with changed members. Grouped by module,
keystats has the most changed areas (13 areas, 124 members) but was campaigned
on 2026-11-04 (`2026-11-04/metrics.md`) and is privacy-heavy; the hotstring
family (hotstrings, dynamic hotstrings, their editors and settings windows:
16 areas, 34 members, plus the Windows engine under `windows/infra`) is the
register's next row and the one this campaign takes. The other changed areas
still need review before a register row can claim them.

## Fixed (macOS, Linux and shared)

| Id      | Sequence                                                                                   | Windows and Linux                                                                                          | macOS before                                              | Regression                   |
| ------- | ------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- | ---------------------------- |
| HCM-001 | 3 arrows, `ab` > `cd`, a private `xcd` > `P`, `cd` > `ef`; type `x`, `ab`                  | The matcher's winner is the longer `xcd`; it is private, so the chain stops: `xcd`                         | Skipped the private winner, fired the shorter `cd`: `xef` | `cascade-link-is-the-winner` |
| HCM-002 | Same with `xcd` > `Q{Left}` (a key output)                                                 | Winner is no link (`_HSE_IsCascadeLink`, `has_key_tokens`): `xcd`                                          | `xef`                                                     | `cascade-link-is-the-winner` |
| HCM-003 | Same with a final `xcd` > `xcd` (a final entry that changes nothing)                       | The final no-op wins with no edit and masks the lower rules (`HSE_FinalNoOpFound`, `best_match_at`): `xcd` | `xef`                                                     | `cascade-link-is-the-winner` |
| HCM-004 | `ab` > `cd`; end-character final `cd` > `CD` of priority 5; auto `cd` > `ef` of priority 1 | `_HSE_FinalEndOutranks` / `final_end_outranks` hold the auto link back: `cd`                               | The cascade never asked: `ef`                             | `cascade-link-is-the-winner` |

One root cause: macOS's `pick_cascade_step` filtered the bucket on "is a
link" before matching and did not apply the typed path's no-op and
outranking rules, so a link could be a rule the same typed text never reaches.
The step now takes the typed matcher's winner and refuses it when it cannot be
a link, as Windows and the shared engine do. The priority control (a lower
final entry leaves the link alone) passes before and after.

| Id      | Sequence                                                                              | Windows (and the other Lua OS)                                                    | Before                                                                      | Regression                                 |
| ------- | ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- | --------------------------------------------------------------------------- | ------------------------------------------ |
| HCL-001 | Linux, conform rule `adn` > `and`; type `Adn`, Space, then Backspace                  | Types back the buffer text, `Adn` (macOS: the matched text)                       | Main typed back `result.trigger`, the stored `adn`                          | `undo-typed-casing` (engine and Main)      |
| HCL-002 | Linux, the undo's restore refused by the destination (focus moved at four boundaries) | `HSE_UndoExpansion` logs an error and resets the context                          | The injector receipt was dropped: no trace                                  | `undo-refusal-reported`                    |
| HCL-003 | Linux, Backspace after a private expansion                                            | « private trigger (content withheld) », no length (macOS the same)                | Logged the private trigger's length                                         | `undo-private-log`                         |
| HCM-005 | macOS, `po★` repeats to `poo`, then Backspace                                         | The repeat goes through the atomic fire and is undoable (Linux records it too)    | `try_repeat_feature` kept no record: the Backspace deleted the `o`          | `undo-repeat` (`test_backspace_undo.lua`)  |
| HCM-006 | macOS, `ab`, a no-break space, `:` fires `cd:`, then Backspace                        | Restores the trigger alone, the no-break space is not typed back (Linux the same) | The record was refused whenever a no-break space was stripped               | `undo-nbsp-stripped`                       |
| HCS-001 | Inventory: macOS Backspace restore, Linux repeat window and consecutive repeat        | —                                                                                 | Declared absent on macOS / Linux after the 2026-11-06 decisions and URL-001 | `test-linux-feature-parity.cjs` projection |

Continued later on November 11 (source `adfc5569`), from the remaining rows below:

| Id      | Sequence                                                        | Windows and Linux                                                                                         | macOS before                                     | Regression           |
| ------- | --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ------------------------------------------------ | -------------------- |
| HCM-007 | Stored number `612345678` (no trunk zero), type `+336123`       | Linux: `+336123` gives `+33612345678` (every digit kept)                                                  | Registered `+33123`, which skips the first digit | `intl-short-trigger` |
| HCM-008 | `td`, a pause longer than the dynamic delay, then the magic key | No date: `TimeActivationSeconds` (`dynamic_hotstrings.ahk:149`), Linux `within_delay` (`manager.lua:603`) | The interceptor had no clock: the date was typed | `date-rule-delay`    |

HCM-007's two triggers are now computed once in the shared
`dynamic_hotstrings` module (`international_phone`, `international_prefix`),
which both Lua drivers call. HCM-008: the keymap hands its interceptors the gap
since the preceding physical key (`ctx.elapsed`) and owns the verdict
(`dynamic_rule_within_delay`, the dynamic family's section delay, the same
resolution as the programmable source); a missing gap fails closed.

The shared engine now reports `typed_trigger` (the erased trigger text, the net
typed text after a cascade that reached further left), so the undo no longer
reads the stored spelling. The Linux cascade test's undo model typed the end
character back, which the daemon never did; it now models the daemon. macOS
had no unit test of the undo at all: `test_backspace_undo.lua` is the first.

## Decisions pending (behaviour left unchanged)

- **HCD-1, an expired best candidate.** Windows (`HSE_TimeGateExpired` in
  `_OnPrefixChar`, then only the repeat fallback) and Linux (`within_delay`
  after `engine:on_char`, then only the repeat) drop the winner whose
  expansion delay expired and fire nothing else. macOS filters each
  candidate on its delay before matching (`mapping_fires` in
  `run_trigger_checks`, `cascade_step_allowed` in the cascade), so a shorter
  or lower-priority rule whose category delay still allows it fires instead.
  This is shipped macOS typing behaviour, so it stays as is until the
  maintainer picks one rule; the macOS cascade keeps the macOS typed-path
  semantics so that the two never disagree.
- **HCD-2, a bare `:` or `;` as an end character.** Windows
  (`hotstring_match.ahk`, « A bare `:` / `;` without preceding nbsp is a
  mid-sequence character (e.g. `:D`) and must not trigger any expansion ») and
  the shared engine (`select_match`, « The space is REQUIRED, not merely
  tolerated ») refuse it. macOS has accepted it since 2026-11-04 (commit
  `f7c48c2b8`, test « bare punctuation must terminate the ordinary mapping » in
  `test_star_validation_beats_repeat_key.lua`): `ab` followed by a bare `:`
  expands on macOS only. Probe: `ab` > `cd` end-character, buffer `ab`, type
  `:` gives `cd:` on macOS. A shipped, tested choice on one OS, so a pending
  decision.

- **HCD-3, the eight named personal tags (privacy).** Windows registers
  `@tel★ @tél★ @rib★ @iban★ @bic★ @cb★ @cc★ @ss★`, each typing one field
  (`infra/personal_info_preview.ahk:40-55`, `hotstrings_text_expansion.ahk:79-96`).
  macOS (`personal_info.lua:510-537`) and Linux (`manager.lua:256-268, 489-494`)
  have no tag table and read each letter as an alias: `@iban★` types IBAN, BIC,
  street and surname separated by Tabs, `@ss★`/`@cc★` type a value twice,
  `@tel★`/`@rib★` nothing (executed on both Lua drivers with synthetic data).
  This types more personal data than asked, so it stays a pending decision.
- **HCD-4, the expansion delay on personal `@` tags and combos.** Windows and
  macOS apply none (`TimeActivationSeconds` 0); Linux gates them by the dynamic
  category's delay since `e64e7faa6`. Personal data and a deliberate Linux
  change: pending.
- **HCD-5, an uppercase one-letter tag `@N★`.** Windows (no `C` flag, the
  fallback lowers the tag) and macOS (case-equivalent aliases) type the field;
  Linux keeps single-letter rules exact-case on purpose (`manager.lua:339-351`,
  « single-field registered rules remain exact ») and types nothing; `@NP★`
  works. Personal data: pending.

## Observations (no change)

- A cascade link that reaches back into typed text measures its delay from
  the typed reference character on Windows (`LastSentCharacterKeyTime`) and
  Linux (the buffer stamps), but from the last keystroke pause on macOS
  (`cascade_elapsed`). Only a one-character first replacement can make the
  reference a typed character; the memory entry `project-hotstring-cascade`
  already records the macOS measure.
- The macOS cascade arrow count is seeded from the manifest default at module
  load (`keymap/init.lua` `M.set_cascade_max_arrows(M.DEFAULT_STATE...)`); the
  neutral `1` in `state.lua` is never the effective value. Refuted.

- The undo's keystats label differs on each OS (Windows marks the output
  synthetic, macOS reports it as an undo, Linux counts the Backspace as a
  correction); none takes back the original fire count. No contract exists.
- Refuted by the sub-audits: what the undo erases (replacement plus the
  replayed end character), what it types back (the trigger alone), what voids
  it (another key, a click, a focus change, a second Backspace; a lone
  modifier keeps it; Ctrl/Alt/Win/Cmd/Option+Backspace stay the
  application's) and the matcher state afterwards agree on the three OSes.
  Eager and fire-time combo assembly, in-word `@` tags, the phone/SSN/IBAN
  triggers other than the row below and the date formats agree; the three
  2026-11-04 fixes have not regressed (executed on the Lua drivers).

## Remaining work

- **macOS:** done (HCM-007, HCM-008 above).
- **Windows (report only):** for a stored number without a leading `0`
  (`612345678`), the short `+33` trigger still drops the first digit
  (`+33123`, `SubStr(Phone, 2, 3)` in `dynamic_hotstrings.ahk:199`); macOS and
  Linux now register `+336123`.
- **Windows (report only):** the inventory still declares no repeat activation
  window on Windows although `HSE_RepeatWindowSeconds` gates it (decision of
  2026-11-06); its row in `behaviors.json` needs the maintainer's review of the
  Windows owner. The Backspace undo is refused in terminals, paste-mode hosts
  and Notepad (`hotstring_dispatch.ahk:1753-1755`; no record on those owners),
  where macOS and Linux restore. Not executed (no AHK runner).
- **Docs:** the documentation block of `prev_char_before` in
  `macos/modules/keymap/expander.lua` is back above its function (November 11).
  The memory entry
  `project-hotstring-cascade` (« each link is chosen by the same matcher a
  typed key goes through ») now holds on macOS too.
- **Native receiving:** none of the fixes was replayed in a real application
  (Hammerspoon event tap, evdev/uinput, AHK).
