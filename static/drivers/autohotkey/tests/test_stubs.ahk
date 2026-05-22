; static/drivers/autohotkey/tests/test_stubs.ahk

; ==============================================================================
; MODULE: Test Stubs
; DESCRIPTION:
; Minimal stubs for the runtime globals and helper functions that the
; production lib/ files reference. Tests need to load those lib files to
; exercise the pure helpers, but the lib files happen to also reference
; functions / Maps initialised by ErgoptiPlus.ahk top-level code (Features,
; ScriptInformation, SendNewResult, …). This file declares dummy versions
; so the tests can ``#Include`` the libs without registering hotkeys or
; touching the file system.
;
; FEATURES & RATIONALE:
; 1. Stubs are global to the test process and used everywhere; loading them
;    once at the top of run_all.ahk is enough.
; 2. Each stub keeps a side-effect log (e.g. ``_Stub_SentText.Push(Text)``)
;    so individual tests can assert that the lib called the stub with the
;    expected arguments — this is how we test Send semantics without an
;    actual keyboard.
; 3. Stubs can be overridden inside a test by reassigning the global; the
;    test framework runs everything in the same compilation unit so the
;    override is visible to the lib code under test.
; ==============================================================================

; ============================================
; ============================================
; ======= 1/ Side-effect recorders =======
; ============================================
; ============================================

global _Stub_SentText := []          ; Recorded SendNewResult / SendInput / SendEvent payloads
global _Stub_LastChars := []         ; Recorded UpdateLastSentCharacter calls
global _Stub_HotstringCalls := []    ; Recorded CreateHotstring / CreateCaseSensitiveHotstrings calls
global _Stub_DeadKeyCalls := []      ; Recorded DeadKey calls

; Recorders consumed by the production ``_HotstringRegistrar`` and ``_SendHook``
; test seams. Populated by InstallHotstringHooks and reset by Reset*Hotstring*.
global _Stub_HotstringRegistrations := []   ; { spec, callback }
global _Stub_RecordedSends := []            ; { fn, args }

ResetStubRecorders() {
    global _Stub_SentText, _Stub_LastChars, _Stub_HotstringCalls, _Stub_DeadKeyCalls
    _Stub_SentText := []
    _Stub_LastChars := []
    _Stub_HotstringCalls := []
    _Stub_DeadKeyCalls := []
}

ResetHotstringRecorders() {
    global _Stub_HotstringRegistrations, _Stub_RecordedSends, _Stub_LastChars, HSE_LastMatch
    _Stub_HotstringRegistrations := []
    _Stub_RecordedSends := []
    _Stub_LastChars := []
    ; HSE_LastMatch may hold a stale match from a prior test (e.g. the v2 engine
    ; test suite), causing _HotstringDispatch to abort via the "yield to longer
    ; trigger" guard. Clear it here so every callback invocation starts clean.
    HSE_LastMatch := ""
}

; =====================================
; =====================================
; ======= 2/ Global state stubs =======
; =====================================
; =====================================

; Mimics the user-configurable script identity from ErgoptiPlus.ahk.
global ScriptInformation := Map(
    "MagicKey", "★",
    "PersonalAhkPath", A_ScriptDir . "\..\personal_shortcuts.ahk",
    "PersonalTomlPath", A_Temp . "\ergopti_test_no_personal_hotstrings.toml",
    "LogLevel", "INFO",
)

; Features v1 Map kept for the slices that have not yet migrated (Personal,
; letter pickers in layout_ergopti, Gestures master toggle in tray_menu).
; New code reads from FeaturesV2 — see ManifestBuildFeaturesMap.
global Features := Map(
    "Layout", Map(
        "ErgoptiBase", { Enabled: true },
        "ErgoptiAltGr", { Enabled: true },
        "ErgoptiPlus", { Enabled: false },
    ),
    "Shortcuts", Map(
        "AltGrLAlt", Map(
            "BackSpace", { Enabled: false },
            "Tab", { Enabled: true },
        ),
        "AltGrCapsLock", Map(
            "BackSpace", { Enabled: false },
            "CapsLock", { Enabled: false },
        ),
    ),
    "DistancesReduction", Map(
        "SpaceAroundSymbols", { Enabled: false },
    ),
    "Gestures", Map(
        "Enabled", { Enabled: true },
    ),
)

; Mirror of the v1 sections that have been migrated to the new v2-shape Map.
; Production populates this via MirrorV1ToV2_<Section>() at boot (see
; lib/v1_v2_mirror.ahk). The migrated read sites (lib/layout/*, modules/
; layout.ahk, modules/gestures.ahk, modules/shortcuts.ahk, modules/
; keylogger/keylogger_prefetch.ahk) now hit FeaturesV2 instead of Features.
; Tests don't fire those hotkeys but the symbol still needs to exist as a
; global so a) the production lib/ files load cleanly and b) future
; test_v2_mirror.ahk fixtures can pin the contract directly.
;
; Each section's keys must match what its MirrorV1ToV2_<Section>() helper
; in lib/v1_v2_mirror.ahk writes — extend both together when a new feature
; is added to the manifest.
global FeaturesV2 := Map(
    "layout", Map(
        "ergopti_base",         true,
        "direct_access_digits", true,
        "ergopti_alt_gr",       true,
        "ergopti_plus",         false,
    ),
    "gestures", Map(
        "enabled", false,
    ),
    "shortcuts", Map(
        ; Plain bools (default = true|false in the manifest).
        "wrap_text_if_selected",    true,
        "get_hex_value",            true,
        "microsoft_bold",           true,
        "title_case",               true,
        "uppercase",                true,
        "paste_without_formatting", false,
        "save",                     false,
        "select_line",              true,
        "spotlight_mouse",          true,
        "surround_with_parentheses", true,
        "teleport_mouse",           true,
        "ctrl_j",                   false,
        "open_downloads",           false,
        "move",                     false,
        "screen",                   false,
        "screen_instant",           false,
        "win_caps_lock",            false,
        ; Modélisation α — Map per feature with { enabled, <extra props> }.
        "gpt", Map(
            "enabled", true,
            "link",    "https://chatgpt.com/",
        ),
        "search", Map(
            "enabled",                 true,
            "search_engine",           "https://www.google.com",
            "search_engine_url_query", "https://www.google.com/search?q=",
        ),
        "take_note", Map(
            "enabled",            true,
            "dated_notes",        false,
            "destination_folder", "D:\\Bureau",
        ),
        ; Sub-Maps — 10 entries each (same key set as the v1 Maps).
        ; Phase 4 migrated the individual reads in modules/shortcuts.ahk
        ; (AltGrLAlt) and modules/tap_holds.ahk (LAltCapsLock); phase 10
        ; added AltGrCapsLock when the dispatcher was inlined.
        "alt_gr_caps_lock", Map(
            "backspace",      false,
            "caps_lock",      false,
            "caps_word",      false,
            "ctrl_backspace", false,
            "ctrl_delete",    true,
            "delete",         false,
            "enter",          false,
            "escape",         false,
            "one_shot_shift", false,
            "tab",            false,
        ),
        "alt_gr_lalt", Map(
            "backspace",      false,
            "caps_lock",      false,
            "caps_word",      false,
            "ctrl_backspace", true,
            "ctrl_delete",    false,
            "delete",         false,
            "enter",          false,
            "escape",         false,
            "one_shot_shift", false,
            "tab",            false,
        ),
        "lalt_caps_lock", Map(
            "backspace",      false,
            "caps_lock",      false,
            "caps_word",      true,
            "ctrl_backspace", false,
            "ctrl_delete",    false,
            "delete",         false,
            "enter",          false,
            "escape",         false,
            "one_shot_shift", false,
            "tab",            false,
        ),
    ),
    ; Phase 5 — modules/hotstrings.ahk + modules/layout.ahk read these gates
    ; for hotstring registration and AltGr rolls. Each entry is a Map with
    ; at least an "enabled" key; the production loader pulls extra props
    ; (time_activation_seconds, pattern_max_length) from the manifest, but
    ; tests don't exercise those — the "enabled" key alone is enough to
    ; satisfy the migrated `if FeaturesV2["hotstrings"][...][...]["enabled"]`
    ; gates without crashing.
    "hotstrings", Map(
        "distances_reduction", Map(
            "qu",                    Map("enabled", true),
            "suffixes_a",            Map("enabled", true),
            "comma_j",               Map("enabled", true),
            "comma_far_letters",     Map("enabled", true),
            "dead_key_e_circumflex", Map("enabled", true),
            "e_circumflex_e",        Map("enabled", true),
            "space_around_symbols",  Map("enabled", true),
        ),
        "sfbs_reduction", Map(
            "comma",     Map("enabled", true),
            "e_circ",    Map("enabled", true),
            "e_grave",   Map("enabled", true),
            "bu",        Map("enabled", true),
            "i_e_acute", Map("enabled", true),
        ),
        "rolls", Map(
            "hc",                       Map("enabled", true),
            "sx",                       Map("enabled", true),
            "cx",                       Map("enabled", true),
            "english_negation",         Map("enabled", true),
            "ez",                       Map("enabled", true),
            "ct",                       Map("enabled", true),
            "close_chevron_tag",        Map("enabled", true),
            "chevron_less",             Map("enabled", true),
            "chevron_greater",          Map("enabled", true),
            "chevron_equal",            Map("enabled", true),
            "comment_open",             Map("enabled", true),
            "comment_close",            Map("enabled", true),
            "assign",                   Map("enabled", true),
            "not_equal",                Map("enabled", true),
            "paren_quote",              Map("enabled", true),
            "bracket_quote",            Map("enabled", true),
            "hashtag_parenthesis",      Map("enabled", true),
            "hashtag_open_bracket",     Map("enabled", true),
            "hashtag_close_bracket",    Map("enabled", true),
            "hashtag_quote",            Map("enabled", true),
            "equal_string",             Map("enabled", true),
            "left_arrow",               Map("enabled", true),
            "assign_arrow_equal_right", Map("enabled", true),
            "assign_arrow_equal_left",  Map("enabled", true),
            "assign_arrow_minus_right", Map("enabled", true),
            "assign_arrow_minus_left",  Map("enabled", true),
        ),
        "autocorrection", Map(
            "typographic_apostrophe",     Map("enabled", true),
            "errors",                     Map("enabled", true),
            "suffixes_a_chaining",        Map("enabled", true),
            "accents",                    Map("enabled", true),
            "caps",                       Map("enabled", true),
            "names",                      Map("enabled", true),
            "minus",                      Map("enabled", true),
            "minus_apostrophe",           Map("enabled", true),
            "ou",                         Map("enabled", true),
            "multiple_punctuation_marks", Map("enabled", true),
        ),
        "magic_key", Map(
            "replace",                      Map("enabled", true),
            "repeat_corrections",           Map("enabled", true),
            "text_expansion",               Map("enabled", true),
            "text_expansion_auto",          Map("enabled", true),
            "text_expansion_emojis",        Map("enabled", true),
            "text_expansion_symbols",       Map("enabled", true),
            "text_expansion_symbols_typst", Map("enabled", true),
        ),
        "dynamic", Map(
            "date",                              Map("enabled", true),
            "date_fr",                           Map("enabled", true),
            "date_long_fr",                      Map("enabled", true),
            "iban_prefixes",                     Map("enabled", true),
            "phone_prefixes",                    Map("enabled", true),
            "ssn_prefixes",                      Map("enabled", true),
            "text_expansion_personal_information", Map("enabled", true, "pattern_max_length", 1),
        ),
    ),
    ; Phase 6 — ui/tray_menu.ahk's LLM tray populator now reads from this
    ; nested map (instead of IniCacheGet) and flattens it back into the
    ; legacy _LlmSavedOpts shape that LLM_Tray_Init expects. Manifest
    ; defaults match production; tests don't fire the LLM menu but the
    ; symbols still need to exist as globals.
    "llm", Map(
        "enabled", false,
        "display", Map(
            "pred_indent",     0,
            "show_info_bar",   true,
            "streaming",       true,
            "streaming_multi", true,
        ),
        "generation", Map(
            "context_length",  500,
            "min_words",       3,
            "max_words",       15,
            "temperature",     0.10,
            "auto_raise_temp", true,
            "reset_on_nav",    true,
            "sequential_mode", false,
        ),
        "models", Map(
            "selected", "ollama",
            "ollama",   "qwen2.5:3b",
        ),
        "profiles", Map(
            "active",                 "basic",
            "num_predictions",        3,
            "auto_profile_for_model", true,
        ),
        "trigger", Map(
            "debounce_ms",          500,
            "instant_on_word_end",  true,
            "after_hotstring",      true,
            "inline_autotype",      false,
            "secure_filter_enabled", true,
            "url_bar_filter_enabled", true,
        ),
        "navigation", Map(
            "val_modifiers", ["alt"],
        ),
    ),
)

; Phase 7.3 — TapHold global is populated in production by
; LoadTapHoldToml + MirrorV1ToV2_TapHold (see lib/v1_v2_mirror.ahk § 6).
; Tests don't exercise tap-hold logic but the symbol must exist for the
; mirror's existence check and any future test_tap_hold_mirror.ahk fixture.
global TapHold := Map("keys", Map(), "layers", Map())

; Phase 7.4 — Master category gating state. Production initialises this
; in ErgoptiPlus.ahk and reloads it from the [CategoryEnabled] TOML
; section; tests don't toggle masters but the global must exist so the
; per-section mirrors' ``IsCategoryGated`` calls return true.
global CategoryEnabled := Map(
    "Layout",     true,
    "Shortcuts",  true,
    "Hotstrings", true,
    "TapHolds",   true,
)
IsCategoryGated(Category) {
    global CategoryEnabled
    return CategoryEnabled.Has(Category) ? CategoryEnabled[Category] : true
}

global ConfigurationFile := A_ScriptDir . "\test_config.ini"
global SpaceAroundSymbols := ""

; ``_StaticDir`` is normally computed by ErgoptiPlus.ahk and read by
; lib/i18n.ahk to build the path to the locale JSON files. Without this stub,
; the very first t() call (e.g. from modules/gestures.ahk's top-level
; GESTURE_SLOT_LABELS builder) raised "global variable has not been assigned a
; value" inside lib/i18n.ahk's _I18nLocalePath helper. AHK then surfaced the
; error as a MsgBox under default settings — invisible but blocking on the
; headless CI runner, which is the root cause of the recurring "5-minute
; timeout" failures of the AHK test suite.
;
; Points at the real ``static/`` tree (three levels up from the tests folder)
; so:
;   - i18n.ahk resolves real locale JSONs and t() returns translated strings
;   - modules/gestures.ahk parses the bundled ``shared/actions.toml`` and
;     populates GESTURE_ACTION_NAMES with the production gesture catalog
;     (the gesture tests would otherwise see an empty registry).
;
; The hotstrings-config tests guard against picking up the bundled
; rolls.toml / autocorrection.toml metadata by pre-caching empty entries in
; ``HotstringGroupConfig`` from ``_HCfgTestReset`` — see test_hotstrings_config.ahk.
global _StaticDir := A_ScriptDir . "\..\..\.."

; Strict-canonicalisation guard read by TOML_RunStrictCanonicalization in
; lib/toml/toml_helpers.ahk. Production declares this in ErgoptiPlus.ahk
; (false) so the canonicaliser knows it is allowed to run; the test runner
; does not include ErgoptiPlus.ahk, so the helper would otherwise raise
; "global variable has not been assigned a value" the first time a test
; writes through TOML_BatchWrite / TOML_Write.
global _TOML_STRICT_CANON_IN_PROGRESS := false

; Hotstring engine globals normally maintained by modules/layout.ahk.
; The LastSentCharacters ring buffer is defined in lib/hotstring_engine.ahk;
; tests seed it via _LSCResetFrom([...]) instead of touching it directly.
global LastSentCharacterKeyTime := Map()
global RemappedList := Map()
; Stub for the INI cache — gestures.ahk reads it at load time via GesturesReadConfig()
global _IniCache := Map()
global InDeadKeySequence := false
global LayerEnabled := false
global CapsWordEnabled := false
global OneShotShiftEnabled := false
global NumberOfRepetitions := 1
global ActivitySimulation := false

; Dummy deadkey Maps so layout_altgr.ahk's _BuildAltGrTables can run.
global DeadkeyMappingCircumflex := Map()
global DeadkeyMappingDiaresis := Map()
global DeadkeyMappingSuperscript := Map()
global DeadkeyMappingSubscript := Map()
global DeadkeyMappingGreek := Map()
global DeadkeyMappingR := Map()
global DeadkeyMappingCurrency := Map()

; ==================================
; ==================================
; ======= 3/ Function stubs =======
; ==================================
; ==================================

; AHK refuses duplicate function definitions, so we can only stub functions
; that are NOT defined in any included lib/ file. The list below covers the
; functions that production lib/ files reference but live in modules/
; (which run_all.ahk deliberately does not #Include).
; Production helpers like SendNewResult / CreateHotstring / ReloadPersonalSection
; are exercised through their real implementations; their downstream effects
; (notably UpdateLastSentCharacter calls and recorded LastSentCharacters
; updates) are the observable surface we assert against.

WrapTextIfSelected(Symbol, LeftSymbol, RightSymbol) {
    global _Stub_SentText
    _Stub_SentText.Push({ kind: "wrap", symbol: Symbol, left: LeftSymbol, right: RightSymbol })
}

UpdateLastSentCharacter(Character) {
    global _Stub_LastChars, LastSentCharacterKeyTime
    _Stub_LastChars.Push(Character)
    _LSCPush(Character)
    LastSentCharacterKeyTime[Character] := A_TickCount
}

DeadKey(Mapping) {
    global _Stub_DeadKeyCalls
    _Stub_DeadKeyCalls.Push(Mapping)
}

; Toggle helpers consulted by tap-hold and shortcut dispatchers.
; Real implementations live in modules/tap_holds.ahk (not included by tests).
ToggleCapsLock() {
    global _Stub_SentText
    _Stub_SentText.Push({ kind: "toggle_capslock" })
}

ToggleCapsWord() {
    global _Stub_SentText
    _Stub_SentText.Push({ kind: "toggle_capsword" })
}

ToggleSuspend() {
    global _Stub_SentText
    _Stub_SentText.Push({ kind: "toggle_suspend" })
}

OneShotShift() {
    global _Stub_SentText
    _Stub_SentText.Push({ kind: "one_shot_shift" })
}

DisableCapsWord() {
    global CapsWordEnabled
    CapsWordEnabled := false
}

GetCapsLockCondition() {
    return false
}

; ==========================================
; ==========================================
; ======= 4/ Hotstring engine hooks =======
; ==========================================
; ==========================================

; Recorder consumed by ``_HotstringRegistrar`` once installed. Stores the
; trigger spec (``:flags:abbrev``) and the callback so individual tests can
; both count registrations and invoke the callback directly to drive
; HotstringHandler with controlled inputs.
_HOOK_RecordHotstring(TriggerSpec, Callback) {
    global _Stub_HotstringRegistrations
    _Stub_HotstringRegistrations.Push({ spec: TriggerSpec, callback: Callback })
}

; Recorder consumed by ``_SendHook``. Captures every send primitive call as
; ``{ fn, args }`` where ``args`` is the variadic Array of positional
; arguments after the function name. Tests assert on the ordered sequence
; to verify backspace counts, replacement payloads and end-character emission.
_HOOK_RecordSend(FnName, Args*) {
    global _Stub_RecordedSends
    _Stub_RecordedSends.Push({ fn: FnName, args: Args })
}

; Wire both hooks into the production globals so subsequent CreateHotstring /
; HotstringHandler / Send* calls record instead of touching the OS.
InstallHotstringHooks() {
    global _HotstringRegistrar, _SendHook
    _HotstringRegistrar := _HOOK_RecordHotstring
    _SendHook := _HOOK_RecordSend
}

UninstallHotstringHooks() {
    global _HotstringRegistrar, _SendHook
    _HotstringRegistrar := 0
    _SendHook := 0
}

; ── Active-app cache simulators — bypass GetActiveApp's WinGet* calls so the
; ── Notepad / Office branches of HotstringHandler can be exercised in tests.
SimulateNotepadActive() {
    global _ActiveAppCache
    _ActiveAppCache.ts := A_TickCount
    _ActiveAppCache.Class := "Notepad"
    _ActiveAppCache.Exe := "notepad.exe"
    _ActiveAppCache.IsNotepad := true
    _ActiveAppCache.IsMicrosoftOffice := false
}

SimulateRegularApp() {
    global _ActiveAppCache
    _ActiveAppCache.ts := A_TickCount
    _ActiveAppCache.Class := "TestApp"
    _ActiveAppCache.Exe := "test.exe"
    _ActiveAppCache.IsNotepad := false
    _ActiveAppCache.IsMicrosoftOffice := false
}

SimulateMicrosoftOffice() {
    global _ActiveAppCache
    _ActiveAppCache.ts := A_TickCount
    _ActiveAppCache.Class := "OpusApp"
    _ActiveAppCache.Exe := "WINWORD.EXE"
    _ActiveAppCache.IsNotepad := false
    _ActiveAppCache.IsMicrosoftOffice := true
}
