# i18n and locale fallback at run time: Windows, macOS and Linux

Audited source: `b61a7b67` (`claude/ergopti-todo-parity-b`, on `dev`
`54e2486f`). Date: November 12, 2026.

## Scope

The run-time half of localisation, from the census areas `infra` (each OS)
and shared `lua/locale`: the first-run and saved-locale choice, the lookup
chain of a key (active locale, English, French, then the raw key), how a miss
is reported, and the probes that test an optional key. The catalogues
themselves (key parity, punctuation) are held by the existing gates
(`tools/locale/check_locales.py`, `test-french-punctuation.cjs`). Windows
(`windows/infra/i18n.ahk`, `windows/infra/locale.ahk`) is the read-only
reference; macOS `infra/i18n.lua`, Linux `infra/i18n.lua`, both over the
shared `_shared/lua/locale/core.lua`. Candidates were replayed through the
real Lua modules; no Hammerspoon or AHK was executed.

## Fixed

| Id      | Sequence                                                        | Windows                                                         | Before                                                              | Regression                        |
| ------- | --------------------------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------- | --------------------------------- |
| I18-001 | A key missing from the active locale, en and fr reaches a label | `t()` warns once per key, « the raw key is being displayed »    | macOS and Linux show the raw key with no log line                   | `i18n-miss-warned` (both drivers) |
| I18-002 | A saved locale without a catalogue (macOS)                      | `LoggerWarn` « Unknown locale … falling back to system locale » | Silent fall back to the system language (Linux already warned)      | `i18n-unknown-saved`              |
| I18-003 | The system language has no catalogue (macOS)                    | `"en"` literal (`_I18nDetectSystemLocale`)                      | A second `"en"` literal beside the shared `locales.system_fallback` | `i18n-system-fallback`            |

I18-001 also gives Linux the `has()` probe macOS already had, and moves the
three callers that probe optional keys onto it, so a probe is never reported
as a miss: an action id from another OS without a catalogue entry (macOS
`gestures/actions.lua` `get_label`), a tap action the gestures manager labels
(Linux `menu_tap_holds.lua`), and a prediction profile without a catalogue
label (Linux `prediction_engine.lua`). Windows probes with `I18nLookup` the
same way.

## Checked and kept

- The lookup chain is the same on the three OSes: the active locale, then
  English, then French, then the raw key (`locale.ahk` `I18nLookup`, shared
  `core.lua` `get`). An empty string counts as a miss everywhere.
- A first run follows the system language with Norwegian bokmål and nynorsk
  mapped to `no` and English as fallback on the three OSes (Linux since
  LCY-002).
- A locale change is persisted before it is applied: Windows reloads the
  script after a debounce, macOS after a transaction-guarded reload timer,
  Linux publishes through the script scope owner.
- The ★ placeholder is substituted with the configured trigger by the lookup
  itself on the three OSes.

## Windows, report only

- **I18W-001.** `_I18nDetectSystemLocale` returns an `"en"` literal where the
  Lua drivers read `locales.system_fallback`
  (`_shared/data/identifiers.json`); `windows/_generated/identifiers.ahk`
  does not emit it yet. Low priority: the value is pinned by the test of each
  driver.

## Left

- Native receiving (a real Hammerspoon `hs.host.locale`, a desktop session
  language) is unqualified.
