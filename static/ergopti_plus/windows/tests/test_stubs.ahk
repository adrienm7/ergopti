; static/ergopti_plus/windows/tests/test_stubs.ahk

; ==============================================================================
; MODULE: Test Stubs
; DESCRIPTION:
; Minimal stubs for the runtime globals and helper functions that the
; production infra/ files reference. Tests need to load those lib files to
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





; ========================================
; ========================================
; ======= 1/ Side-effect recorders =======
; ========================================
; ========================================

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

; v2 Features Map — canonical state container. Hydrated at boot from the
; user's v2 config.toml by ApplyConfigToml. All runtime reads go through
; Features directly.
;
; The fixture below mirrors the manifest defaults — extend it alongside
; any new feature added to static/ergopti_plus/_shared/modules/features/manifest.toml
; so existing tests don't break when a new HotIf reads Features["…"].
global Features := Map(
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
        ; Letter pickers (phase 11) — accented base-layer keys, configurable
        ; target latin letter consumed by ErgoptiBaseMapping.
        "e_grave",  Map("enabled", true, "letter", "z"),
        "e_circ",   Map("enabled", true, "letter", "x"),
        "e_acute",  Map("enabled", true, "letter", "c"),
        "a_grave",  Map("enabled", true, "letter", "v"),
        ; Sub-Maps — 10 entries each (same key set as the v1 Maps).
        ; A later refactor migrated the individual reads in modules/shortcuts.ahk
        ; (AltGrLAlt) and platform/remap.ahk (LAltCapsLock); phase 10
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
    ; modules/hotstrings.ahk + modules/keymap/layout.ahk read these gates
    ; for hotstring registration and AltGr rolls. Each entry is a Map with
    ; at least an "enabled" key; the production loader pulls extra props
    ; (time_activation_seconds, pattern_max_length) from the manifest, but
    ; tests don't exercise those — the "enabled" key alone is enough to
    ; satisfy the migrated `if Features["hotstrings"][...][...]["enabled"]`
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
        ; Personal sub-Map — in production this is populated from the user's
        ; personal_hotstrings.toml [_meta.sections] block (via BootstrapPersonalFeatures
        ; + the reverse mirror); tests pre-seed a representative shape so the
        ; v2 read sites in modules/hotstrings.ahk and
        ; ui/personal_toml_editor.ahk find a configured Map.
        "personal", Map(
            "autocorrection", Map("enabled", true, "time_activation_seconds", 0.75),
            "code",           Map("enabled", true, "time_activation_seconds", 0.75),
        ),
    ),
    ; ui/tray_menu.ahk's LLM tray populator now reads from this
    ; nested map (instead of IniCacheGet) and flattens it back into the
    ; legacy _LlmSavedOpts shape that LLM_Menu_Init expects. Manifest
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

; TapHold global is populated in production by LoadTapHoldToml from the
; user's tap_hold.toml. Tests don't exercise tap-hold logic but the symbol
; must exist so the per-key TapHoldIsConfigured(KeyId) lookups return
; cleanly.
global TapHold := Map("keys", Map(), "layers", Map())

; Master category gating state. Production initialises this in
; ErgoptiPlus.ahk and reloads it from the [category_enabled] TOML
; section; tests don't toggle masters but the global must exist so
; ``IsCategoryGated`` calls return true.
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
; infra/i18n.ahk to build the path to the locale JSON files. Without this stub,
; the very first t() call (e.g. from modules/gestures.ahk's top-level
; GESTURE_SLOT_LABELS builder) raised "global variable has not been assigned a
; value" inside infra/i18n.ahk's _I18nLocalePath helper. AHK then surfaced the
; error as a MsgBox under default settings — invisible but blocking on the
; headless CI runner, which is the root cause of the recurring "5-minute
; timeout" failures of the AHK test suite.
;
; Points at the real ``static/`` tree (three levels up from the tests folder)
; so:
;   - i18n.ahk resolves real locale JSONs and t() returns translated strings
;   - modules/gestures.ahk parses the bundled ``_shared/actions.toml`` and
;     populates GESTURE_ACTION_NAMES with the production gesture catalog
;     (the gesture tests would otherwise see an empty registry).
;
; The hotstrings-config tests guard against picking up the bundled
; rolls.toml / autocorrection.toml metadata by pre-caching empty entries in
; ``HotstringGroupConfig`` from ``_HCfgTestReset`` — see test_hotstrings_config.ahk.
global _StaticDir := A_ScriptDir . "\..\..\.."
global _SharedDir := _StaticDir . "\ergopti_plus\_shared"
global _DriverDir := _StaticDir . "\ergopti_plus\windows"
; Mirrors the entry point's sub-root for extension packs. Any new pre-pump global
; in ErgoptiPlus.ahk must be mirrored here or the first read from a unit test
; raises "global variable has not been assigned a value".
global _ExtensionsDir := _StaticDir . "\ergopti_plus\extensions"

; Strict-canonicalisation guard read by TOML_RunStrictCanonicalization in
; infra/toml/toml_helpers.ahk. Production declares this in ErgoptiPlus.ahk
; (false) so the canonicaliser knows it is allowed to run; the test runner
; does not include ErgoptiPlus.ahk, so the helper would otherwise raise
; "global variable has not been assigned a value" the first time a test
; writes through TOML_BatchWrite / TOML_Write.
global _TOML_STRICT_CANON_IN_PROGRESS := false

; Hotstring engine globals normally maintained by modules/keymap/layout.ahk.
; The LastSentCharacters ring buffer is defined in infra/hotstring_engine.ahk;
; tests seed it via _LSCResetFrom([...]) instead of touching it directly.
global LastSentCharacterKeyTime := Map()
global RemappedList := Map()
; Stub for the INI cache — gestures.ahk reads it at load time via GesturesReadConfig()
global _IniCache := Map()
global InDeadKeySequence := false
global LayerEnabled := false
global CapsWordEnabled := false
; Mirrors the ErgoptiPlus.ahk pre-pump block, which owns the seed for every global a
; parse-time #HotIf reads (see LayerEnabled/CapsWordEnabled/TapHold above). It lives
; there rather than in hotstring_engine.ahk because that file's include position sits
; below the first message pump; the headless harness never loads ErgoptiPlus.ahk, so
; it must seed the same sentinel here.
global _ALTGR_KANA_FIXUP := false
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





; =================================
; =================================
; ======= 3/ Function stubs =======
; =================================
; =================================

; AHK refuses duplicate function definitions, so we can only stub functions
; that are NOT defined in any included infra/ file. The list below covers the
; functions that production infra/ files reference but live in modules/
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

    ; We use dynamic lookup to avoid load-time "unassigned variable" warnings
    ; and "conflicting global" errors. This handles cases where some tests
    ; do not include hotstring_engine.ahk or app_state.ahk.
    _LSCPush_Fn := 0
    try _LSCPush_Fn := % "_LSCPush" %
    if IsObject(_LSCPush_Fn) {
        _LSCPush_Fn(Character)
    }

    LastSentCharacterKeyTime[Character] := A_TickCount

    ; Also mirror into AppState so modules that read AppState["last_sent_key_time"]
    ; observe the same timestamp as modules that read LastSentCharacterKeyTime.
    _Touch_Fn := 0
    try _Touch_Fn := % "AppState_TouchLastSentKey" %
    if IsObject(_Touch_Fn) {
        _Touch_Fn(Character)
    }
}

DeadKey(Mapping) {
    global _Stub_DeadKeyCalls
    _Stub_DeadKeyCalls.Push(Mapping)
}

; UpdateCapsLockLED lives in modules/shortcuts/capsword.ahk (not included).
; nav_layer_helpers.ahk calls it after toggling LayerEnabled.
UpdateCapsLockLED() {
    global _Stub_SentText
    _Stub_SentText.Push({ kind: "update_capslock_led" })
}

; Toggle helpers consulted by tap-hold and shortcut dispatchers.
; Real implementations live in platform/remap.ahk (not included by tests).
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

; The pause-preserving reload. The real one lives in infra/lifecycle.ahk, which
; this runner cannot include: it defines ToggleSuspend, colliding with the stub
; above, and loading the genuine article would let a test actually Suspend(1) the
; runner and arm its watchdog timers. Stubbed rather than IsSet-guarded at the
; call sites so production keeps ONE reload rule with no silent fallback — a
; guarded call would degrade to a bare Reload exactly where the guarantee
; matters. Records the request so a test can assert the pause was carried.
ReloadPreservingSuspend() {
    global _Stub_SentText
    _Stub_SentText.Push({ kind: "reload_preserving_suspend" })
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





; =========================================
; =========================================
; ======= 4/ Hotstring engine hooks =======
; =========================================
; =========================================

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

; ── Active-app cache simulators — bypass WinGet* calls so the
; ── Notepad / Office branches of HotstringHandler can be exercised in tests.
SimulateNotepadActive() {
    global KLHook
    if !IsSet(KLHook)
        KLHook := {}
    KLHook.prev_app := "notepad.exe"
    KLHook.prev_title := "Untitled - Notepad"
}

SimulateRegularApp() {
    global KLHook
    if !IsSet(KLHook)
        KLHook := {}
    KLHook.prev_app := "test.exe"
    KLHook.prev_title := "Test App"
}

SimulateMicrosoftOffice() {
    global KLHook
    if !IsSet(KLHook)
        KLHook := {}
    KLHook.prev_app := "WINWORD.EXE"
    KLHook.prev_title := "Document - Word"
}




; =============================================
; =============================================
; ======= 5/ Dry-run OS guard ================
; =============================================
; =============================================

; Replaces the injectable send primitives from adapters/text_sender.ahk with
; no-ops so no real keystroke ever reaches the OS while tests are running.
; This mirrors the _SendHook pattern used for hotstring engine tests.
; _AHK_SendText and _AHK_SendInput are declared as globals in text_sender.ahk
; and re-assigned here (test_stubs.ahk is loaded before the adapter in run_all.ahk,
; so these globals are declared here first and overwritten when text_sender.ahk
; loads — we therefore install the no-op AFTER the adapter is included, via a
; dedicated function called from run_all.ahk's body).
global _AHK_SendText  := (Text) => 0   ; no-op — never reaches SendText()
global _AHK_SendInput := (Keys) => 0   ; no-op — never reaches SendInput()

; InstallSendNoOps must be called AFTER #Include text_sender.ahk in run_all.ahk
; to win the last-assignment race and lock both globals to no-ops.
InstallSendNoOps() {
    global _AHK_SendText, _AHK_SendInput
    _AHK_SendText  := (Text) => 0
    _AHK_SendInput := (Keys) => 0
}




; =====================================================================
; ====================================================================
; ======= 6/ LLM prediction engine stubs =============================
; ====================================================================
; =====================================================================

; These functions are called by modules/llm/prediction_engine.ahk at
; runtime. In production they live in ui/tooltip/tooltip_llm.ahk and
; modules/keylogger/keylogger.ahk (which register hotkeys or OS hooks
; and therefore cannot be #Included by the test runner). The stubs
; below record calls so individual tests can assert on them.

global _Stub_LlmTooltipCalls   := []   ; recorded LLM_Tooltip_Show calls
global _Stub_LlmLogCalls       := []   ; recorded KL_LogLlm calls
global _Stub_LlmLogFailedCalls := []   ; recorded KL_LogLlmFailed calls
global _Stub_LlmSuggestedCalls := []   ; recorded KL_LogLlmSuggested calls

global LLM_TOOLTIP_PLACEHOLDER := "★"

LLM_Tooltip_Show(slots, active := 1, is_final := false) {
    global _Stub_LlmTooltipCalls
    _Stub_LlmTooltipCalls.Push({ slots: slots, active: active, is_final: is_final })
}

LLM_Tooltip_SetDisplayOpts(Opts) {
    ; no-op for tests
}

LLM_Tooltip_ShowLoading() {
    global _Stub_LlmTooltipCalls
    _Stub_LlmTooltipCalls.Push({ loading: true })
}

LLM_Tooltip_Hide(accepted := false) {
    global _Stub_LlmTooltipCalls
    _Stub_LlmTooltipCalls.Push({ hide: true, accepted: accepted })
}

; Visibility probes used by the engine to decide whether to paint the violet
; loading spinner (macOS parity: keep an existing prediction instead of
; replacing it with a spinner). Default false so the spinner path runs exactly as
; before; a test may flip these globals to simulate a prediction already on screen.
global _Stub_LlmTooltipVisible := false
global _Stub_LlmTooltipLoading := false

LLM_Tooltip_IsVisible() {
    global _Stub_LlmTooltipVisible
    return _Stub_LlmTooltipVisible
}

LLM_Tooltip_IsLoading() {
    global _Stub_LlmTooltipLoading
    return _Stub_LlmTooltipLoading
}

LLM_Deps_IsReady() {
    return true
}

KL_LogLlm(event_type, evt) {
    global _Stub_LlmLogCalls
    _Stub_LlmLogCalls.Push({ event_type: event_type, evt: evt })
}

KL_LogLlmFailed(evt) {
    global _Stub_LlmLogFailedCalls
    _Stub_LlmLogFailedCalls.Push({ evt: evt })
}

KL_LogLlmSuggested(app_name, count) {
    global _Stub_LlmSuggestedCalls
    _Stub_LlmSuggestedCalls.Push({ app_name: app_name, count: count })
}

class Keylogger {
    static synth_active := 0
    static synth_type   := "none"
    ; Needed by KL_BuildInserts / KL_AllocEventId (modules/keylogger/keylogger_sql.ahk)
    ; when that pure builder module is exercised directly from unit tests.
    static _device_id_lit := "'test-device'"
    ; Raw (unquoted) id, used by KL_BuildInsertTyping to derive the at-rest
    ; encryption IV per row.
    static device_id      := "test-device"
    static next_event_id  := 1
    ; Ledger location + lifecycle flag, read by modules/keylogger/
    ; keylogger_text_migration.ahk. AHK v2 THROWS on an undeclared static, so a
    ; missing field here is a crash in the migration test rather than a skip.
    static initialized    := false
    static by_device_dir  := ""
    static data_sql_path  := ""
}

; Synthetic keystroke tagging. In production this lives in keylogger.ahk.
; The test stub mirrors the depth-counter logic so test_suppress_refcount.ahk
; can verify the refcounting behaviour.
KL_MarkSynthetic(source) {
    Keylogger.synth_active += 1
    Keylogger.synth_type := source
}

; Clears the synthetic-keystroke flag after a hotstring burst. In production
; this lives in keylogger.ahk (not included by the test runner). The variadic
; signature matches the real function so SetTimer can pass it directly.
KL_ClearSynthetic(*) {
    Keylogger.synth_active := Max(0, Keylogger.synth_active - 1)
    if !Keylogger.synth_active
        Keylogger.synth_type := "none"
}

; Atomic file write — in production lives in keylogger.ahk (not included by
; the test runner). The test stub does a direct write without the rename dance;
; atomicity is not required in a single-process test environment.
KL_WriteAtomic(path, content) {
    try FileDelete(path)
    FileAppend(content, path, "UTF-8")
}

