# Migration v1 → v2 — exhaustive mapping reference

This document is the **single reference** for the Scope C cut-over. It enumerates every v1 key (TOML section, TOML key, in-memory `Features` Map path, AHK access pattern, `IniCacheGet` call site) and its v2 destination.

It is **not** a tutorial — it is a lookup table consumed by the migration agent. Read top-down once for orientation, then jump to the relevant section when rewriting a specific call site.

**Scope**: this document covers the AHK side (Windows driver). The Hammerspoon counterpart is symmetrical but its `_state.config` table already lives in snake_case, so the HS migration is mostly section restructuring (Modélisation α + platform prefix) without a global identifier rename.

## Conventions

- **v1** = current state on `dev` and earlier. PascalCase TOML + mixed PascalCase/snake_case `Features` Map + AHK object property access (`.Enabled`, `.Letter`).
- **v2** = target state on this branch. snake_case TOML + snake_case `Features` Map + AHK Map index access (`["enabled"]`, `["letter"]`). The `ahk.` prefix is **stripped at load time** by `ManifestBuildFeaturesMap` so call sites stay at one level of nesting (`Features["layout"]`, not `Features["ahk"]["layout"]`).
- All v2 leaf containers are AHK `Map()` (string-keyed), never `{key: value}` objects. This is a deliberate uniformity choice — see Section 9 for the access-pattern rationale.

## Source files reference

| Concern | v1 location | v2 location |
|---|---|---|
| Hardcoded defaults (AHK) | [`lib/features_config.ahk`](../../autohotkey/lib/features_config.ahk) (380 lines) | Replaced by `ManifestBuildFeaturesMap()` call (manifest is the source of truth) |
| Hardcoded tap-hold defaults (AHK) | [`lib/tap_hold_config.ahk`](../../autohotkey/lib/tap_hold_config.ahk) | `config/ergopti_plus/ahk/tap_hold.toml` (per-driver file, seeded from [`windows/data/tap_hold/defaults.toml`](../../windows/data/tap_hold/defaults.toml) at first boot) |
| User overrides | `config/ergopti_plus/ahk/config.toml` (PascalCase mixed) | Same path, but v2 schema (snake_case nested) |
| Personal info | `config/ergopti_plus/personal_info.toml` | Same path, v2 schema (snake_case) |
| Hotstrings group meta | `config/ergopti_plus/hotstrings_config.toml` | Same path, v2 schema (snake_case) |
| TOML loader | [`lib/toml/toml_loader.ahk`](../../autohotkey/lib/toml/toml_loader.ahk) (`ApplyConfigToml`) | [`lib/toml/toml_loader_v2.ahk`](../../autohotkey/lib/toml/toml_loader_v2.ahk) (`ApplyConfigTomlV2`) |

## Affected call-site files (17 + boot file)

Every file below references the `Features` global or uses `IniCacheGet`. The cut-over rewrites all of them.

1. `ErgoptiPlus.ahk` — boot wiring, `ApplyTomlMetadataToFeatures`, `IniCacheGet` for Hotstrings/Script/Layout/Personal
2. `lib/features_config.ahk` — DELETED (replaced by `ManifestBuildFeaturesMap()` call from `lib/manifest_reader.ahk`)
3. `lib/tap_hold_config.ahk` — DELETED (per-driver `tap_hold.toml` is the new source)
4. `lib/toml/toml_loader.ahk` — DELETED (v2 loader supersedes it)
5. `lib/dispatchers.ahk` — reads `Features["Shortcuts"]…`
6. `lib/layout/layout_altgr.ahk` — reads `Features["Shortcuts"]["AltGrLAlt"]…`
7. `lib/layout/layout_ergopti.ahk` — reads `Features["Layout"]…` + `IniCacheGet("Layout", …)`
8. `lib/layout/layout_shift_caps.ahk` — reads `Features["Shortcuts"]…`
9. `lib/hotstrings/personal_toml_editor.ahk` — reads `Features["Personal"]…`
10. `lib/i18n.ahk` — `IniCacheGet("Script", "Locale")`
11. `lib/onboarding.ahk` — `IniCacheGet("Layout", "ErgoptiBase"|…)`, `IniCacheGet("Hotstrings", "MagicKey")`
12. `lib/updater.ahk` — `IniCacheGet(UPDATER_INI_SECTION, …)` (unrelated to Features, leave as-is — INI is the updater's own file)
13. `lib/metrics/wpm_widget.ahk` — `IniCacheGet("Script", "WpmWidget…")` → DELETED (WpmWidget dropped from AHK in v2)
14. `lib/toml/toml_helpers.ahk` — utility, may need v2 awareness
15. `modules/gestures.ahk` — reads `Features["Gestures"]…` + `IniCacheGet("Gestures", …)` + `IniCacheGet("Shortcuts.Actions", …)`
16. `modules/hotstrings.ahk` — reads `Features["DistancesReduction"|"SFBsReduction"|"Rolls"|"Autocorrection"|"MagicKey"]…` (~99 occurrences)
17. `modules/layout.ahk` — reads `Features["Layout"]…`
18. `modules/shortcuts.ahk` — reads `Features["Shortcuts"]…` (~42 occurrences)
19. `modules/tap_holds.ahk` — reads `Features["TapHolds"]…` (~70 occurrences) — see Section 7 for the structural change
20. `modules/keylogger/keylogger_prefetch.ahk` — reads `Features["Personal"]…`
21. `ui/tray_menu.ahk` — reads `Features[…]` extensively (~20 occurrences) + `IniCacheGet("LLM", …)`
22. `tests/test_toml_loader.ahk`, `tests/test_config.ahk` — rewrite to test v2 loader

## Top-level section renames

The hardcoded `__Order` array in `features_config.ahk` is replaced by `manifest.toml [sections] order` (codegen preserves it in `Features["section_order"]`).

| v1 `Features[…]` | v2 `Features[…]` (after `ahk.` strip) | Note |
|---|---|---|
| `Features["__Order"]` | `Features["section_order"]` | Codegen-emitted |
| `Features["Layout"]` | `Features["layout"]` | AHK-only — manifest path is `ahk.layout`, stripped to `layout` |
| `Features["DistancesReduction"]` | `Features["hotstrings"]["distances_reduction"]` | Moved under universal `hotstrings` |
| `Features["SFBsReduction"]` | `Features["hotstrings"]["sfbs_reduction"]` | Moved under universal `hotstrings` |
| `Features["Rolls"]` | `Features["hotstrings"]["rolls"]` | Moved under universal `hotstrings` |
| `Features["Autocorrection"]` | `Features["hotstrings"]["autocorrection"]` | Moved under universal `hotstrings` |
| `Features["MagicKey"]` | `Features["hotstrings"]["magic_key"]` | Moved under universal `hotstrings` |
| `Features["DynamicHotstrings"]` | `Features["hotstrings"]["dynamic"]` | Moved + renamed (`Dynamic` group lives under `hotstrings.dynamic`) |
| `Features["Personal"]` (hotstrings) | `Features["hotstrings"]["personal"]` | Moved under universal `hotstrings` |
| `Features["Shortcuts"]` | `Features["shortcuts"]` for universal entries, `Features["ahk"]["shortcuts"]` for Windows-only | Split: see Section 6 |
| `Features["TapHolds"]` | **REMOVED from Features** — see Section 7 (separate `TapHold` global from `tap_hold.toml`) | Tap-hold is no longer a `Features` sub-tree |
| `Features["Gestures"]` | `Features["gestures"]` (after `ahk.` strip from `ahk.gestures`) | AHK-only |

## 1. Layout (AHK-only — `[Layout]` → `[ahk.layout]`)

| v1 TOML | v1 `Features` path | v2 TOML | v2 `Features` path |
|---|---|---|---|
| `[Layout] ErgoptiBase = true` | `Features["Layout"]["ErgoptiBase"].Enabled` | `[ahk.layout] ergopti_base = true` | `Features["layout"]["ergopti_base"]` |
| `[Layout] DirectAccessDigits = true` | `Features["Layout"]["DirectAccessDigits"].Enabled` | `[ahk.layout] direct_access_digits = true` | `Features["layout"]["direct_access_digits"]` |
| `[Layout] ErgoptiAltGr = true` | `Features["Layout"]["ErgoptiAltGr"].Enabled` | `[ahk.layout] ergopti_alt_gr = true` | `Features["layout"]["ergopti_alt_gr"]` |
| `[Layout] ErgoptiPlus = true` | `Features["Layout"]["ErgoptiPlus"].Enabled` | `[ahk.layout] ergopti_plus = true` | `Features["layout"]["ergopti_plus"]` |

**Note**: v2 layout features are now plain booleans (no `enabled` sub-key), because the manifest declares `default = true` (primitive), not `default = { enabled = true }` (table). The access pattern goes from `.Enabled` to a direct boolean read.

`IniCacheGet("Layout", "ErgoptiBase")` → `Features["layout"]["ergopti_base"]` (already populated by `ApplyConfigTomlV2`).

## 2. Hotstrings (universal — `[Hotstrings]` → `[hotstrings]`)

### 2.0 Top-level

| v1 TOML | v1 `Features` path | v2 TOML | v2 `Features` path |
|---|---|---|---|
| `[Hotstrings] MagicKey = "★"` | n/a (read via `IniCacheGet`) | `[hotstrings] trigger_char = "★"` | `Features["hotstrings"]["trigger_char"]` |

The `MagicKey` key is **semantically renamed** to `trigger_char` to avoid confusion with the `MagicKey` feature group (the keystroke that triggers `[hotstrings.magic_key.*]` expansions).

`IniCacheGet(Cache, "Hotstrings", "MagicKey")` → `Features["hotstrings"]["trigger_char"]`.

### 2.1 Autocorrection — `[Hotstrings.Autocorrection]` → `[hotstrings.autocorrection.<entry>]`

**Structural change (Modélisation α)**: each entry becomes its own sub-section with `enabled` + optional `time_activation_seconds`.

| v1 TOML | v1 `Features` path | v2 TOML | v2 `Features` path |
|---|---|---|---|
| `Accents = true` + `Accents_TimeActivationSeconds = 0.5` | `Features["Autocorrection"]["Accents"].Enabled` | `[hotstrings.autocorrection.accents] enabled = true; time_activation_seconds = 0.5` | `Features["hotstrings"]["autocorrection"]["accents"]["enabled"]` and `["time_activation_seconds"]` |
| `Caps = true` + `Caps_TimeActivationSeconds = 0.5` | `Features["Autocorrection"]["Caps"].Enabled` | `[hotstrings.autocorrection.caps]` | `Features["hotstrings"]["autocorrection"]["caps"]…` |
| `Errors = …` | `Features["Autocorrection"]["Errors"].Enabled` | `[hotstrings.autocorrection.errors]` | `Features["hotstrings"]["autocorrection"]["errors"]…` |
| `Minus = …` | `Features["Autocorrection"]["Minus"].Enabled` | `[hotstrings.autocorrection.minus]` | `Features["hotstrings"]["autocorrection"]["minus"]…` |
| `MinusApostrophe = …` | `Features["Autocorrection"]["MinusApostrophe"].Enabled` | `[hotstrings.autocorrection.minus_apostrophe]` | `Features["hotstrings"]["autocorrection"]["minus_apostrophe"]…` |
| `MultiplePunctuationMarks = …` | `Features["Autocorrection"]["MultiplePunctuationMarks"].Enabled` | `[hotstrings.autocorrection.multiple_punctuation_marks]` | `Features["hotstrings"]["autocorrection"]["multiple_punctuation_marks"]…` |
| `Names = …` | `Features["Autocorrection"]["Names"].Enabled` | `[hotstrings.autocorrection.names]` | `Features["hotstrings"]["autocorrection"]["names"]…` |
| `OU = …` | `Features["Autocorrection"]["OU"].Enabled` | `[hotstrings.autocorrection.ou]` | `Features["hotstrings"]["autocorrection"]["ou"]…` |
| `SuffixesAChaining = …` | `Features["Autocorrection"]["SuffixesAChaining"].Enabled` | `[hotstrings.autocorrection.suffixes_a_chaining]` | `Features["hotstrings"]["autocorrection"]["suffixes_a_chaining"]…` |
| `TypographicApostrophe = …` | `Features["Autocorrection"]["TypographicApostrophe"].Enabled` | `[hotstrings.autocorrection.typographic_apostrophe]` | `Features["hotstrings"]["autocorrection"]["typographic_apostrophe"]…` |

### 2.2 Distances reduction — `[Hotstrings.DistancesReduction]` → `[hotstrings.distances_reduction.<entry>]`

| v1 id | v2 id | Has delay? |
|---|---|---|
| `QU` | `qu` | yes (0.5) |
| `SuffixesA` | `suffixes_a` | yes (0.5) |
| `CommaJ` | `comma_j` | no (instant) |
| `CommaFarLetters` | `comma_far_letters` | no |
| `DeadKeyECircumflex` | `dead_key_e_circumflex` | no |
| `ECircumflexE` | `e_circumflex_e` | yes (0.5) |
| `SpaceAroundSymbols` | `space_around_symbols` | no |

v1 `Features["DistancesReduction"]["QU"].Enabled` → v2 `Features["hotstrings"]["distances_reduction"]["qu"]["enabled"]`.

### 2.3 SFBs reduction — `[Hotstrings.SFBsReduction]` → `[hotstrings.sfbs_reduction.<entry>]`

| v1 id | v2 id | Has delay? |
|---|---|---|
| `Comma` | `comma` | yes (0.5) |
| `ECirc` | `e_circ` | yes (0.5) |
| `EGrave` | `e_grave` | yes (0.5) |
| `BU` | `bu` | no |
| `IÉ` | `i_e_acute` | no — **note the ASCII rename** (was an accented identifier!) |

v1 `Features["SFBsReduction"]["IÉ"].Enabled` → v2 `Features["hotstrings"]["sfbs_reduction"]["i_e_acute"]["enabled"]`.

### 2.4 Rolls — `[Hotstrings.Rolls]` → `[hotstrings.rolls.<entry>]`

| v1 id | v2 id | Has delay? |
|---|---|---|
| `HC` | `hc` | yes (0.5) |
| `SX` | `sx` | yes (0.5) |
| `CX` | `cx` | yes (0.5) |
| `CT` | `ct` | yes (0.5) |
| `EZ` | `ez` | yes (0.5) |
| `Assign` | `assign` | no |
| `AssignArrowEqualLeft` | `assign_arrow_equal_left` | no |
| `AssignArrowEqualRight` | `assign_arrow_equal_right` | no |
| `AssignArrowMinusLeft` | `assign_arrow_minus_left` | no |
| `AssignArrowMinusRight` | `assign_arrow_minus_right` | no |
| `BracketQuote` | `bracket_quote` | no |
| `ChevronEqual` | `chevron_equal` | no |
| `ChevronGreater` | `chevron_greater` | no |
| `ChevronLess` | `chevron_less` | no |
| `CloseChevronTag` | `close_chevron_tag` | yes (0.5) |
| `CommentClose` | `comment_close` | yes (0.5) |
| `CommentOpen` | `comment_open` | yes (0.5) |
| `EnglishNegation` | `english_negation` | no |
| `EqualString` | `equal_string` | no |
| `HashtagCloseBracket` | `hashtag_close_bracket` | yes (0.5) |
| `HashtagOpenBracket` | `hashtag_open_bracket` | yes (0.5) |
| `HashtagParenthesis` | `hashtag_parenthesis` | yes (0.5) |
| `HashtagQuote` | `hashtag_quote` | no |
| `LeftArrow` | `left_arrow` | no |
| `NotEqual` | `not_equal` | no |
| `ParenQuote` | `paren_quote` | no |

### 2.5 Magic key — `[Hotstrings.MagicKey]` → `[hotstrings.magic_key.<entry>]`

| v1 id | v2 id | Default delay |
|---|---|---|
| `Replace` | `replace` | n/a |
| `RepeatCorrections` | `repeat_corrections` | 2.0 |
| `TextExpansion` | `text_expansion` | 2.0 |
| `TextExpansionAuto` | `text_expansion_auto` | 2.0 |
| `TextExpansionEmojis` | `text_expansion_emojis` | 2.0 |
| `TextExpansionSymbols` | `text_expansion_symbols` | 2.0 |
| `TextExpansionSymbolsTypst` | `text_expansion_symbols_typst` | 2.0 |

### 2.6 Dynamic hotstrings — `[Hotstrings.DynamicHotstrings]` → `[hotstrings.dynamic.<entry>]`

Group is renamed from `DynamicHotstrings` to `dynamic` (the parent section already says `hotstrings`, so the `Hotstrings` suffix is redundant).

| v1 id | v2 id | Extra fields |
|---|---|---|
| `Date` | `date` | — |
| `DateFr` | `date_fr` | — |
| `DateLongFr` | `date_long_fr` | — |
| `IbanPrefixes` | `iban_prefixes` | — |
| `PhonePrefixes` | `phone_prefixes` | — |
| `SsnPrefixes` | `ssn_prefixes` | — |
| `TextExpansionPersonalInformation` | `text_expansion_personal_information` | `pattern_max_length = 1` (was `PatternMaxLength`) |

### 2.7 Personal — `[Hotstrings.Personal]` → `[hotstrings.personal.<entry>]`

| v1 id | v2 id | Default delay |
|---|---|---|
| `Autocorrection` | `autocorrection` | 0.75 |
| `Code` | `code` | 0.75 |
| `Emailshortcuts` | `email_shortcuts` | 0.75 — **also fixed casing** (`Emailshortcuts` → `email_shortcuts`) |
| `Professionalvocabulary` | `professional_vocabulary` | 0.75 — **also fixed casing** |
| `Test` | `test` | 0.75 |

## 3. LLM — `[LLM]` → `[llm.*]`

**Major restructuring**: the flat `[LLM]` section is split into six sub-sections: `display`, `generation`, `models`, `profiles`, `trigger`, `navigation`. All `IniCacheGet(_IniCache, "LLM", …)` calls (mostly in `ui/tray_menu.ahk`) become direct `Features["llm"][…]` reads.

| v1 TOML key | v2 path | Note |
|---|---|---|
| `[LLM] enabled` | `Features["llm"]["enabled"]` | Stays at top |
| `[LLM] pred_indent` | `Features["llm"]["display"]["pred_indent"]` | Moved to display |
| `[LLM] show_info_bar` | `Features["llm"]["display"]["show_info_bar"]` | (new in v2, not present in user v1 example) |
| `[LLM] streaming` / `streaming_multi` | `Features["llm"]["display"]["streaming"]` / `["streaming_multi"]` | (new in v2) |
| `[LLM] ctx_chars` | `Features["llm"]["generation"]["context_length"]` | **Renamed** |
| `[LLM] min_words` / `max_words` / `temperature` | `Features["llm"]["generation"][...]` | Moved to generation |
| `[LLM] model` | `Features["llm"]["models"]["selected"]` + `Features["llm"]["models"]["ollama"]` | **Split**: v1 had one model id; v2 has a backend selector + per-backend model. Migration: read v1 `model = "qwen2.5:3b"` → set `selected = "ollama"` + `ollama = "qwen2.5:3b"` |
| `[LLM] profile_id` | `Features["llm"]["profiles"]["active"]` | **Renamed** |
| `[LLM] n_predictions` | `Features["llm"]["profiles"]["num_predictions"]` | **Renamed** + moved |
| `[LLM] auto_profile_for_model` | `Features["llm"]["profiles"]["auto_profile_for_model"]` | Moved |
| `[LLM] debounce_ms` | `Features["llm"]["trigger"]["debounce_ms"]` | Moved |
| `[LLM] instant_on_word_end` | `Features["llm"]["trigger"]["instant_on_word_end"]` | Moved |
| `[LLM] inline_autotype` | `Features["llm"]["trigger"]["inline_autotype"]` | Moved |
| `[LLM] app_profile_overrides` | (kept somewhere — TBD if needed in manifest) | — |
| `[LLM] onboarding_seen` | n/a (state, not a feature) | This is a runtime flag, not a config — keep in INI for now or move to a state file |

## 4. Metrics — `[Metrics]` → `[metrics]` + `[ahk.metrics]`

The flat `metrics_*` keys lose the redundant `metrics_` prefix (already inside `[metrics]`). Some keys move to `[ahk.metrics]` (Windows-specific) and some are dropped.

| v1 TOML key | v2 path | Note |
|---|---|---|
| `metrics_enabled` | `Features["metrics"]["enabled"]` | Prefix dropped |
| `metrics_filter_private_browsing` | `Features["ahk"]["metrics"]["filter_private_browsing"]` (after `ahk.` strip: `Features["metrics"]["filter_private_browsing"]`) | Moved to AHK-specific (InPrivate Edge / Incognito Chrome detection is Win-only) |
| `metrics_filter_secure_field` | `Features["metrics"]["secure_filter_enabled"]` | **Renamed** (universal concept) |
| `metrics_filter_system_auth` | `Features["metrics"]["system_auth_filter_enabled"]` | **Renamed** |
| `metrics_show_wpm_menubar` | n/a — **DROPPED from AHK** (HS-only widget) | See Section 11 |
| `metrics_wpm_menubar_colors` | n/a — **DROPPED from AHK** | See Section 11 |
| `metrics_disabled_apps = []` | `Features["metrics"]["disabled_apps"]["list"]` (array under sub-section) | Sub-section per AHK example |
| `metrics_shortcut_apps = ""` | `Features["metrics"]["shortcuts"]["apps"]` | Sub-section |
| `metrics_shortcut_typing = ""` | `Features["metrics"]["shortcuts"]["typing"]` | Sub-section |

**Note**: the v2 example config (`ahk_config.example.toml`) still contains `show_wpm_menubar` and `wpm_menubar_colors` under `[metrics]` — these are **dropped from the manifest**, so the example file must be cleaned up during cut-over.

## 5. Script — `[Script]` → `[script]`

| v1 TOML key | v2 path | Note |
|---|---|---|
| `Locale` | `Features["script"]["locale"]` | Casing |
| (new) `log_level` | `Features["script"]["log_level"]` | New in v2 — exposes the logger threshold |
| (new) `alt_gr_is_kana_remap` | `Features["script"]["alt_gr_is_kana_remap"]` | Replaces the `IniCacheGet("Script", "AltGrIsKanaRemap")` call site (already migrated in commit 3311c2a2 — but key path changes) |
| `WpmWidgetColors`, `WpmWidgetGraph`, `WpmWidgetVisible`, `WpmWidgetX`, `WpmWidgetY` | **DROPPED from AHK** (HS-only widget) | Delete `lib/metrics/wpm_widget.ahk` |

`IniCacheGet(Cache, "Script", "Locale")` → `Features["script"]["locale"]`.
`IniCacheGet(Cache, "Script", "AltGrIsKanaRemap")` → `Features["script"]["alt_gr_is_kana_remap"]`.

## 6. Shortcuts — `[Shortcuts]` → `[shortcuts]` + `[ahk.shortcuts]`

The flat `[Shortcuts]` section is **split** into universal (`[shortcuts]`) and AHK-only (`[ahk.shortcuts]`) namespaces. Sub-Maps (`AltGrLAlt`, `AltGrCapsLock`, `LAltCapsLock`) become sub-sections under `[ahk.shortcuts.<name>]`.

### 6.1 Universal entries (read by AHK + HS)

| v1 TOML key + parameters | v1 `Features` path | v2 path | Note |
|---|---|---|---|
| `EGrave = true` + `EGrave_Letter = "z"` | `Features["Shortcuts"]["EGrave"]` (object with `.Enabled` + `.Letter`) | `Features["shortcuts"]["e_grave"]["enabled"]` + `["letter"]` | Modélisation α extended |
| `ECirc = true` + `ECirc_Letter = "x"` | `Features["Shortcuts"]["ECirc"]` | `Features["shortcuts"]["e_circ"]["enabled"]` + `["letter"]` | — |
| `EAcute = true` + `EAcute_Letter = "c"` | `Features["Shortcuts"]["EAcute"]` | `Features["shortcuts"]["e_acute"]["enabled"]` + `["letter"]` | — |
| `AGrave = true` + `AGrave_Letter = "v"` | `Features["Shortcuts"]["AGrave"]` | `Features["shortcuts"]["a_grave"]["enabled"]` + `["letter"]` | — |
| `WrapTextIfSelected` | `Features["Shortcuts"]["WrapTextIfSelected"].Enabled` | `Features["shortcuts"]["wrap_text_if_selected"]` (bool) | Now a plain bool |
| `GetHexValue` | `Features["Shortcuts"]["GetHexValue"].Enabled` | `Features["shortcuts"]["get_hex_value"]` (bool) | — |
| `GPT = true` + `GPT_Link = "…"` | `Features["Shortcuts"]["GPT"]` (object with `.Enabled` + `.Link`) | `Features["shortcuts"]["gpt"]["enabled"]` + `["link"]` | Modélisation α |
| `Search = true` + `Search_SearchEngine` + `Search_SearchEngineURLQuery` | `Features["Shortcuts"]["Search"]` | `Features["shortcuts"]["search"]["enabled"]` + `["search_engine"]` + `["search_engine_url_query"]` | Modélisation α |
| `TakeNote = true` + `TakeNote_DatedNotes` + `TakeNote_DestinationFolder` | `Features["Shortcuts"]["TakeNote"]` | `Features["shortcuts"]["take_note"]["enabled"]` + `["dated_notes"]` + `["destination_folder"]` | Modélisation α |
| `MicrosoftBold` | `Features["Shortcuts"]["MicrosoftBold"].Enabled` | `Features["shortcuts"]["microsoft_bold"]` (bool) | — |
| `TitleCase` | `Features["Shortcuts"]["TitleCase"].Enabled` | `Features["shortcuts"]["title_case"]` (bool) | — |
| `Uppercase` | `Features["Shortcuts"]["Uppercase"].Enabled` | `Features["shortcuts"]["uppercase"]` (bool) | — |
| `PasteWithoutFormatting` | `Features["Shortcuts"]["PasteWithoutFormatting"].Enabled` | `Features["shortcuts"]["paste_without_formatting"]` (bool) | — |
| `Save` | `Features["Shortcuts"]["Save"].Enabled` | `Features["shortcuts"]["save"]` (bool) | — |
| `SelectLine` | `Features["Shortcuts"]["SelectLine"].Enabled` | `Features["shortcuts"]["select_line"]` (bool) | — |
| `SpotlightMouse` | `Features["Shortcuts"]["SpotlightMouse"].Enabled` | `Features["shortcuts"]["spotlight_mouse"]` (bool) | — |
| `SurroundWithParentheses` | `Features["Shortcuts"]["SurroundWithParentheses"].Enabled` | `Features["shortcuts"]["surround_with_parentheses"]` (bool) | — |
| `TeleportMouse` | `Features["Shortcuts"]["TeleportMouse"].Enabled` | `Features["shortcuts"]["teleport_mouse"]` (bool) | — |

### 6.2 AHK-only entries — `[Shortcuts]` → `[ahk.shortcuts]`

| v1 TOML key | v1 `Features` path | v2 path |
|---|---|---|
| `CtrlJ` | `Features["Shortcuts"]["CtrlJ"].Enabled` | `Features["ahk"]["shortcuts"]["ctrl_j"]` (after `ahk.` strip: `Features["shortcuts"]["ctrl_j"]` — **but** Section 9 explains the access pattern: the `ahk.` prefix is stripped by `ManifestBuildFeaturesMap`, so the in-memory key is `Features["shortcuts"]["ctrl_j"]` — same path as universal entries) |
| `OpenDownloads` | `Features["Shortcuts"]["OpenDownloads"].Enabled` | `Features["shortcuts"]["open_downloads"]` |
| `Move` | `Features["Shortcuts"]["Move"].Enabled` | `Features["shortcuts"]["move"]` |
| `Screen` | `Features["Shortcuts"]["Screen"].Enabled` | `Features["shortcuts"]["screen"]` |
| `ScreenInstant` | `Features["Shortcuts"]["ScreenInstant"].Enabled` | `Features["shortcuts"]["screen_instant"]` |
| `WinCapsLock` | `Features["Shortcuts"]["WinCapsLock"].Enabled` | `Features["shortcuts"]["win_caps_lock"]` |

**Implementation note**: because `ManifestBuildFeaturesMap` strips the `ahk.` prefix, all shortcuts (universal or AHK-only) end up at the **same path** `Features["shortcuts"][…]` from the AHK driver's point of view. The split only matters in the TOML file (so the HS driver doesn't see the AHK-only entries).

### 6.3 AltGrLAlt sub-Map — `[Shortcuts.AltGrLAlt]` → `[ahk.shortcuts.alt_gr_lalt]`

10 entries, all booleans. snake_case for both keys and sub-keys.

| v1 path | v2 path |
|---|---|
| `Features["Shortcuts"]["AltGrLAlt"]["BackSpace"].Enabled` | `Features["shortcuts"]["alt_gr_lalt"]["backspace"]` |
| `Features["Shortcuts"]["AltGrLAlt"]["CapsLock"].Enabled` | `Features["shortcuts"]["alt_gr_lalt"]["caps_lock"]` |
| `Features["Shortcuts"]["AltGrLAlt"]["CapsWord"].Enabled` | `Features["shortcuts"]["alt_gr_lalt"]["caps_word"]` |
| `Features["Shortcuts"]["AltGrLAlt"]["CtrlBackSpace"].Enabled` | `Features["shortcuts"]["alt_gr_lalt"]["ctrl_backspace"]` |
| `Features["Shortcuts"]["AltGrLAlt"]["CtrlDelete"].Enabled` | `Features["shortcuts"]["alt_gr_lalt"]["ctrl_delete"]` |
| `Features["Shortcuts"]["AltGrLAlt"]["Delete"].Enabled` | `Features["shortcuts"]["alt_gr_lalt"]["delete"]` |
| `Features["Shortcuts"]["AltGrLAlt"]["Enter"].Enabled` | `Features["shortcuts"]["alt_gr_lalt"]["enter"]` |
| `Features["Shortcuts"]["AltGrLAlt"]["Escape"].Enabled` | `Features["shortcuts"]["alt_gr_lalt"]["escape"]` |
| `Features["Shortcuts"]["AltGrLAlt"]["OneShotShift"].Enabled` | `Features["shortcuts"]["alt_gr_lalt"]["one_shot_shift"]` |
| `Features["Shortcuts"]["AltGrLAlt"]["Tab"].Enabled` | `Features["shortcuts"]["alt_gr_lalt"]["tab"]` |

### 6.4 AltGrCapsLock sub-Map — `[Shortcuts.AltGrCapsLock]` → `[ahk.shortcuts.alt_gr_caps_lock]`

Same 10 entries as 6.3, same renaming rules.

### 6.5 LAltCapsLock sub-Map — `[Shortcuts.LAltCapsLock]` → `[ahk.shortcuts.lalt_caps_lock]`

Same 10 entries as 6.3, same renaming rules.

### 6.6 Personal sub-Map — `[Shortcuts.Personal]` → `[ahk.shortcuts.personal]`

| v1 id | v2 id |
|---|---|
| `LaptopBrokenKey` | `laptop_broken_key` |
| `MouseDragWindow` | `mouse_drag_window` |
| `MouseTabSwitching` | `mouse_tab_switching` |
| `ProfessionalEnvironment` | `professional_environment` |
| `ProgrammableKeyboard` | `programmable_keyboard` |

`IniCacheGet(_IniCache, "Shortcuts.Personal", Name . ".Enabled")` → `Features["shortcuts"]["personal"][snake_name]`.

### 6.7 ScriptControl sub-Map — `[Shortcuts.ScriptControl]` → `[ahk.shortcuts.script_control]`

These are already in snake_case in v1. Just the section path moves.

| v1 TOML | v2 TOML |
|---|---|
| `[Shortcuts.ScriptControl] script_altgr_backspace = "script_save_reload"` | `[ahk.shortcuts.script_control] script_altgr_backspace = "script_save_reload"` |
| `[Shortcuts.ScriptControl] script_altgr_delete = "open_personal_shortcuts"` | `[ahk.shortcuts.script_control] script_altgr_delete = "open_personal_shortcuts"` |
| `[Shortcuts.ScriptControl] script_altgr_enter = "script_pause_toggle"` | `[ahk.shortcuts.script_control] script_altgr_enter = "script_pause_toggle"` |
| `[Shortcuts.ScriptControl] script_altgr_escape = "script_quit"` | `[ahk.shortcuts.script_control] script_altgr_escape = "script_quit"` |

`IniCacheGet(_IniCache, "Shortcuts.ScriptControl", Slot)` → `Features["shortcuts"]["script_control"][Slot]`.

### 6.8 Actions sub-Map — `[Shortcuts.Actions]` → does NOT exist in v2

The `[Shortcuts.Actions]` section in v1 is read by `gestures.ahk` to resolve action parameters (`open_url`, `take_note_dated`, etc.). In v2, those parameters are folded into the corresponding shortcut sub-sections (`Features["shortcuts"]["search"]["search_engine"]`, etc.). Call sites in `modules/gestures.ahk` need to read from the new locations.

## 7. TapHolds — `[TapHolds]` → `tap_hold.toml` (separate file, separate global)

**Major structural change**: tap-hold is no longer part of the `Features` Map. It lives in its own file `config/ergopti_plus/ahk/tap_hold.toml` and is loaded into a separate global (proposal: `TapHold` or `_TapHold`).

The v2 model is a flat list of keys, each with a single tap action + optional hold layer or hold modifier (mutually exclusive). The v1 sub-Maps (`CapsLock` containing multiple `BackSpaceCtrl`/`EnterCtrl`/… variants) are flattened: each combination becomes a sub-key with `tap_action` + `hold_modifier`.

### 7.1 v1 sub-Map structure (REMOVED)

```
Features["TapHolds"]["CapsLock"]["EnterCtrl"].Enabled   ; one of N variants
Features["TapHolds"]["CapsLock"]["__Configuration"].TimeActivationSeconds
Features["TapHolds"]["LShiftCopy"].Enabled              ; flat entry
Features["TapHolds"]["LShiftCopy"].TimeActivationSeconds
Features["TapHolds"]["LAlt"]["BackSpaceLayer"].Enabled  ; sub-Map variant
```

### 7.2 v2 structure (per-key, single action)

```toml
[tap_hold.keys.caps_lock]
time_activation_seconds = 0.35
tap_action = "enter"
hold_modifier = "ctrl"
```

Read in AHK as `TapHold["keys"]["caps_lock"]["tap_action"]` and `…["hold_modifier"]`.

The migration must collapse the v1 "multi-variant per key" structure (e.g., `CapsLock` had 11 mutually-exclusive `BackSpaceCtrl`/`CapsLockCtrl`/`CapsWordCtrl`/… variants, only one of which is `Enabled: True` at a time) into a **single chosen variant per key**. For the default config: only `EnterCtrl = true` was the active variant → v2 `tap_action = "enter"`, `hold_modifier = "ctrl"`.

### 7.3 Per-key v1 → v2 mapping

| v1 key + active variant | v2 `[tap_hold.keys.<id>]` body | Note |
|---|---|---|
| `CapsLock` + `EnterCtrl: True` (default) | `time_activation_seconds = 0.35; tap_action = "enter"; hold_modifier = "ctrl"` | Other 10 variants are now alternative `tap_action` values |
| `LShiftCopy: True` | `[tap_hold.keys.left_shift] time_activation_seconds = 0.35; tap_action = "copy"; hold_modifier = "shift"` | — |
| `LCtrlPaste: True` | `[tap_hold.keys.left_ctrl] time_activation_seconds = 0.2; tap_action = "paste"; hold_modifier = "ctrl"` | — |
| `LAlt` + `BackSpaceLayer: True` (default) | `[tap_hold.keys.left_alt] time_activation_seconds = 0.2; tap_action = "backspace"; hold_layer = "nav"` | Hold = layer, not modifier |
| `Space` + nothing enabled (default) | `[tap_hold.keys.space] enabled = false` | All v1 variants are `Enabled: False` by default |
| `AltGr` + `Tab: True` (default) | `[tap_hold.keys.alt_gr] time_activation_seconds = 0.2; tap_action = "tab"; hold_modifier = "alt_gr"` | — |
| `RCtrl` + `OneShotShift: True` (default) | `[tap_hold.keys.right_ctrl] time_activation_seconds = 0.35; tap_action = "one_shot_shift"; hold_modifier = "shift"` | — |
| `TabAlt: True` | `[tap_hold.keys.tab] time_activation_seconds = 0.2; tap_action = "alt_tab_monitor"; hold_modifier = "alt"` | — |

### 7.4 Call sites

The ~70 `Features["TapHolds"]…` references in `modules/tap_holds.ahk` plus references in other files all need to read from the new `TapHold` global. The structure is fundamentally different (no more "which variant is enabled" branching — there's only one variant per key), so the migration is **not** mechanical here — it requires understanding what each branch does and replacing it with the equivalent `TapHold["keys"][<key>]["tap_action"]` lookup.

**Action items**:
- Implement a new `lib/tap_hold/tap_hold_loader.ahk` that reads `<config_dir>/ahk/tap_hold.toml` into the `TapHold` global.
- Rewrite `modules/tap_holds.ahk` to drive its `#HotIf` guards from the new structure.
- Remove `lib/tap_hold_config.ahk` entirely.

## 8. Gestures — `[Gestures]` → `[ahk.gestures]`

Same as Layout: AHK-only section, `ahk.` prefix stripped at load.

| v1 TOML key | v1 `Features` path | v2 TOML | v2 path |
|---|---|---|---|
| `[Gestures] Enabled = true` | `Features["Gestures"]["Enabled"].Enabled` | `[ahk.gestures] enabled = true` | `Features["gestures"]["enabled"]` (plain bool) |
| `[Gestures] swipe_3_down = "tab_close"` | n/a (read via `IniCacheGet("Gestures", "swipe_3_down")`) | `[ahk.gestures] swipe_3_down = "tab_close"` | `Features["gestures"]["swipe_3_down"]` |
| ... (10 action slots: `swipe_3_*`, `swipe_4_*`, `tap_3`, `tap_4`) | — | — | — |

**Note**: the v1 `Features["Gestures"]["Enabled"].Enabled` access pattern collapses to `Features["gestures"]["enabled"]` (no double "Enabled"). This is a deliberate simplification — the v1 nesting was awkward.

`IniCacheGet(_IniCache, "Gestures", Slot)` → `Features["gestures"][Slot]` (where Slot is already in snake_case).

The boot-time `IniCacheGet("Gestures", "AutoConfigureOnNextStart")` is **state**, not feature config — move to a separate state file or keep in INI for now.

## 9. Access pattern changes (object → Map, dot → bracket)

### 9.1 v1 object literals → v2 Maps

v1 used AHK object literals `{Enabled: True, TimeActivationSeconds: 0.5}` everywhere. These supported dot access (`.Enabled`). v2 uses `Map("enabled", true, "time_activation_seconds", 0.5)` exclusively, accessed by bracket.

| v1 | v2 |
|---|---|
| `Features["…"]["Foo"].Enabled` | `Features["…"]["foo"]["enabled"]` |
| `Features["…"]["Foo"].Letter` | `Features["…"]["foo"]["letter"]` |
| `Features["…"]["Foo"].TimeActivationSeconds` | `Features["…"]["foo"]["time_activation_seconds"]` |
| `Features["…"]["Foo"].HasOwnProp("Letter")` | `Features["…"]["foo"].Has("letter")` |

### 9.2 Type-check pattern (defensive code)

Many v1 sites do:

```autohotkey
if (IsObject(Features["X"]["Y"]) and Features["X"]["Y"].HasOwnProp("Enabled")) {
    ...
}
```

In v2, since every container is a `Map` (built by the manifest reader), the check simplifies to:

```autohotkey
if (Features["x"]["y"].Has("enabled")) {
    ...
}
```

### 9.3 Plain boolean entries (no `enabled` sub-key)

When the manifest declares `default = true` (primitive bool) instead of `default = { enabled = true }`, the in-memory value is **a plain bool**, not a Map. Examples: every entry in `[ahk.layout]`, the universal toggles like `microsoft_bold`/`title_case`/`uppercase`, and most of `[ahk.shortcuts]`.

v1: `if Features["Layout"]["ErgoptiBase"].Enabled` → v2: `if Features["layout"]["ergopti_base"]`.

This means call sites doing `.Enabled` on a v1 plain-toggle entry must drop the `.Enabled` in v2. Mechanical rule:

- If the v1 entry has **only** an `Enabled` property → v2 is a plain bool → drop `.Enabled` / `["enabled"]`.
- If the v1 entry has **multiple** properties (`Enabled` + `Letter` / `Link` / `TimeActivationSeconds` / …) → v2 is a Map → use `["enabled"]`.

## 10. IniCacheGet call sites — full replacement table

All `IniCacheGet(Cache, "Section", "Key")` calls below disappear in v2 (the value is already in `Features` after `ApplyConfigTomlV2`).

| File:line | v1 call | v2 replacement |
|---|---|---|
| `ErgoptiPlus.ahk:392` | `IniCacheGet(Cache, "Hotstrings", "MagicKey")` | `Features["hotstrings"]["trigger_char"]` |
| `ErgoptiPlus.ahk:396` | `IniCacheGet(Cache, "Script", "MagicKey")` | (legacy fallback — delete; manifest has `trigger_char` only) |
| `ErgoptiPlus.ahk:403` | `IniCacheGet(Cache, "Script", "AltGrIsKanaRemap")` | `Features["script"]["alt_gr_is_kana_remap"]` |
| `ErgoptiPlus.ahk:408` | `IniCacheGet(Cache, "Hotstrings", "RepeatKeyEnabled")` | Not in manifest yet — investigate (likely dropped or moved to `[hotstrings.magic_key]`) |
| `ErgoptiPlus.ahk:718` | `IniCacheGet("Shortcuts.Personal", Name . ".Enabled")` | `Features["shortcuts"]["personal"][snake_name]` |
| `ErgoptiPlus.ahk:931` | `IniCacheGet("Personal", FeatKey . ".Enabled")` | `Features["hotstrings"]["personal"][snake_key]` |
| `ErgoptiPlus.ahk:1581` | `IniCacheGet("Shortcuts.ScriptControl", Slot)` | `Features["shortcuts"]["script_control"][Slot]` |
| `ErgoptiPlus.ahk:1683` | `IniCacheGet("Shortcuts.Keyboard", Slot)` | (`Shortcuts.Keyboard` not in manifest — investigate) |
| `ErgoptiPlus.ahk:522, 534, 539, 547, 552` | `ApplyTomlMetadataToFeatures` engine reading arbitrary `TomlCat . "." . Feature` | **DELETED** — `ApplyConfigTomlV2` walks the v2 schema directly |
| `lib/i18n.ahk:254` | `IniCacheGet(Cache, "Script", "Locale")` | `Features["script"]["locale"]` |
| `lib/onboarding.ahk:516-518` | `IniCacheGet(Cache, "Layout", "ErgoptiBase"|…)` | `Features["layout"]["ergopti_base"]` etc. |
| `lib/onboarding.ahk:527` | `IniCacheGet(Cache, "Hotstrings", "MagicKey")` | `Features["hotstrings"]["trigger_char"]` |
| `lib/updater.ahk:104, 135` | `IniCacheGet(_IniCache, UPDATER_INI_SECTION, …)` | **KEEP AS-IS** — updater uses its own INI file, not the user config |
| `lib/metrics/wpm_widget.ahk:*` | `IniCacheGet("Script", "WpmWidget…")` | **DELETED** — file is removed (HS-only widget) |
| `ui/tray_menu.ahk:1111-1140` | `IniCacheGet(_IniCache, "LLM", …)` (7 calls) | `Features["llm"][…]` — see Section 3 for the per-key mapping |
| `modules/gestures.ahk:660, 676, 678, 725, 726` | `IniCacheGet(_IniCache, "Shortcuts.Actions", …)` | Read from `Features["shortcuts"]["<shortcut>"]["<param>"]` directly (see Section 6.8) |
| `modules/gestures.ahk:1601` | `IniCacheGet(_IniCache, "Gestures", Slot)` | `Features["gestures"][Slot]` |
| `modules/gestures.ahk:1804` | `IniCacheGet(_IniCache, "Gestures", "AutoConfigureOnNextStart")` | State, not config — keep in INI or move to state file |

## 11. Removed features (deleted with no v2 equivalent)

| v1 path | Rationale |
|---|---|
| `[Script] WpmWidgetColors` / `WpmWidgetGraph` / `WpmWidgetVisible` / `WpmWidgetX` / `WpmWidgetY` | WPM widget is HS-only in v2 (no AHK widget) — delete `lib/metrics/wpm_widget.ahk` |
| `[Metrics] metrics_show_wpm_menubar` / `metrics_wpm_menubar_colors` | Same — HS-only |
| `[Hotstrings] RepeatKeyEnabled` | Not in manifest — investigate whether to add or drop |
| `[Shortcuts.Keyboard]` | Not in manifest — investigate (may have been programmable-keyboard related) |
| `Features["TapHolds"]` tree | Moved to separate `TapHold` global from `tap_hold.toml` — see Section 7 |
| All `__Order` arrays in `Features` sub-Maps | Replaced by manifest-driven `section_order` |
| All `__Configuration` keys under TapHold sub-Maps | Per-key `time_activation_seconds` lives directly in `[tap_hold.keys.<id>]` |

## 12. Personal info — `personal_info.toml`

| v1 | v2 |
|---|---|
| `[info] FirstName = "Adrien"` | `[info] first_name = "Adrien"` |
| `[info] LastName = "Moyaux"` | `[info] last_name = "Moyaux"` |
| `[info] PhoneNumber = "…"` | `[info] phone_number = "…"` |
| `[info] StreetAddress = "…"` | `[info] street_address = "…"` |
| `[letters] a = "StreetAddress"` | `[letters] a = "street_address"` |
| `[letters] f = "FirstName"` | `[letters] f = "first_name"` |
| etc. | Value casing also migrated (the value is a key into `[info]`, so it must match) |

## 13. Hotstrings config — `hotstrings_config.toml`

v1 has per-group `[_meta] delay` fields. v2 keeps this structure but applies snake_case everywhere. The schema is already documented in [SCHEMA.md](../config_schema/SCHEMA.md) — no major restructuring needed beyond casing.

## 14. Cut-over checklist (for the migration agent)

When you start the cut-over, do these in order:

1. **Run `npm run build:manifest`** to ensure `static/drivers/autohotkey/_generated/features_manifest.ahk` exists. Without it, `manifest_reader.ahk` will refuse to load and the driver will not boot.
2. **Delete the user's existing config**: `config/ergopti_plus/ahk/config.toml` — the first-boot module will regenerate it from the v2 template. (This is the "clean state, no backward compat" decision.)
3. **Wire boot order in `ErgoptiPlus.ahk`**:
   - Replace `#Include lib/features_config.ahk` with `#Include lib/manifest_reader.ahk` (already present as dormant `#Include`).
   - Right after globals are declared (before any feature module loads), call `global Features := ManifestBuildFeaturesMap()`.
   - Call `EnsureUserConfigsExist()` to bootstrap the v2 config + tap_hold files.
   - Call `ApplyConfigTomlV2(_ConfigDir . "\ahk\config.toml")` to apply user overrides.
   - Apply the same pattern for tap-hold.
4. **File-by-file migration** in this order (low-risk first, high-fanout last):
   1. `modules/layout.ahk` (~10 sites)
   2. `lib/layout/layout_ergopti.ahk` (~5 sites)
   3. `lib/layout/layout_altgr.ahk` (~4 sites)
   4. `lib/layout/layout_shift_caps.ahk` (~3 sites)
   5. `modules/gestures.ahk` (~7 sites + `IniCacheGet`)
   6. `lib/dispatchers.ahk` (~1 site)
   7. `modules/shortcuts.ahk` (~42 sites — the biggest single-file impact after `hotstrings.ahk`)
   8. `modules/hotstrings.ahk` (~99 sites — by far the biggest)
   9. `lib/hotstrings/personal_toml_editor.ahk` (~2 sites)
   10. `modules/keylogger/keylogger_prefetch.ahk` (~3 sites)
   11. `ui/tray_menu.ahk` (~20 sites + 7 `IniCacheGet`)
   12. `lib/i18n.ahk` (~1 `IniCacheGet`)
   13. `lib/onboarding.ahk` (~6 `IniCacheGet`)
   14. `modules/tap_holds.ahk` (~70 sites — but **NOT mechanical**, see Section 7.4)
   15. `ErgoptiPlus.ahk` itself (boot order + remaining `IniCacheGet`)
5. **Delete legacy files**:
   - `lib/features_config.ahk`
   - `lib/tap_hold_config.ahk`
   - `lib/toml/toml_loader.ahk`
   - `lib/metrics/wpm_widget.ahk`
6. **Rename the v2 loader** from `lib/toml/toml_loader_v2.ahk` to `lib/toml/toml_loader.ahk` (drop the `_v2` suffix now that it's the only one).
7. **Tests**: rewrite `tests/test_toml_loader.ahk` and `tests/test_config.ahk` against the v2 loader. Add a meta-test that scans `Features` recursively and asserts no key contains uppercase letters.
8. **Sanity boot**: launch the driver, verify no `WARN` messages about unknown TOML paths, verify every tray-menu item still works.

## 15. Approach decision — bundled vs sliced

Once this document exists, two paths are viable:

- **(a) Three mini-cut-over commits with a temporary compat shim**: emit a wrapper that exposes the v1 path while reading from the v2 `Features`. Allows the migration to proceed file-by-file with the driver bootable at each step. Adds throwaway code.
- **(b) Big Bang Agent run with this document as reference**: a single sweep across all 22 files, no compat shim, no intermediate boot. Riskier but cleaner — no throwaway code, the diff tells the whole story.

The user's preference at the end of the design session was to **revisit this choice with fresh eyes** before launching the agent. Read this document end-to-end first; if Section 7 (tap-hold) looks daunting on second reading, fall back to (a). Otherwise (b) is preferable for a clean-state refactor.

## References

- [SCHEMA.md](../config_schema/SCHEMA.md) — Human-readable v2 schema documentation
- [`manifest.toml`](manifest.toml) — Single source of truth for features
- [`manifest.schema.json`](manifest.schema.json) — JSON Schema for the manifest itself
- [`tap_hold.schema.json`](../config_schema/tap_hold.schema.json) — Sub-schema for tap-hold
- [Dormant cut-over modules]: [`lib/manifest_reader.ahk`](../../autohotkey/lib/manifest_reader.ahk), [`lib/first_boot.ahk`](../../autohotkey/lib/first_boot.ahk), [`lib/toml/toml_loader_v2.ahk`](../../autohotkey/lib/toml/toml_loader_v2.ahk)
