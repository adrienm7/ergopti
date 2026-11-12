# Onboarding wizard: Windows, macOS and Linux

Audited source: `2530aaaa` (`claude/ergopti-todo-parity-b`, on `dev`).
Date: November 12, 2026.

## Scope

The census area `ui/onboarding` (changed on the three OSes) with the shared
page (`_shared/ui/onboarding/`), its generated catalogue
(`_shared/ui/_generated/onboarding_catalogue.json`, from the features
manifest's `[onboarding]`) and the shared answer validator
(`_shared/lua/onboarding_answers.lua`). Windows (`windows/ui/onboarding/`) is
the read-only reference. Bridge messages were replayed through the real macOS
host with its delivery fixture; no WebView was rendered.

## Fixed (macOS)

| Id      | Sequence                                                                          | Windows / Linux                                                                                                             | macOS before                                                                                                                                | Regression                 |
| ------- | --------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------- |
| OBM-001 | Choose a language on the first step, then close the wizard or have Finish refused | Windows records `_ob_locale` and translates its host strings through `_Onboarding_Translate`; Linux only validates the code | `set_locale_no_reload` at `localeSelected`: the menus switched to an unsaved language, and a refused Finish « restored » that same language | `onboarding-locale-choice` |
| OBM-002 | A page message carrying no locale, or one the build does not ship                 | Windows `_OnbWeb_LocaleShipped`, Linux `locale_available`: refused                                                          | `previewLocale` and `localeSelected` substituted `"en"`                                                                                     | `onboarding-locale-choice` |

Both are one change: the chosen language is recorded, the page and its
window title are rebuilt in it from its locale file, the host's dialogs
during the wizard read it the same way, and Finish switches and persists it.

## Checked and kept

- The three hosts read one generated catalogue with the same seven pages; a
  host states `gesture_registration`, and only Windows offers the system
  gesture registration (macOS and Linux answer `{ supported = false }`).
- Platform differences in the catalogue are recorded decisions: Linux
  recommends no swipe (the touchpad is read without a grab, so the desktop
  acts on the same swipes: maintainer decision of 2026-11-03) and has no
  Hotstrings master (on as soon as one group is on); macOS keeps its
  tap-hold switch in `tap_hold.toml`.
- Answers are validated against the catalogue before any write on the three
  OSes, and a refused Finish restores the folder and the language
  (`test_onboarding_failed_finish_restores_choices.lua`).
- The metrics path follows the data directory, not the chosen configuration
  folder, on the three OSes.

## Left

- Linux shows its host dialogs during the wizard in the running language,
  not the previewed one (the page itself follows the preview). Low impact;
  not changed.
- Native WebView receiving is unqualified.
