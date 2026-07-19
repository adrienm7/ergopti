; lib/feature_state.ahk

; ==============================================================================
; MODULE: Feature & Shortcut State Tables
; DESCRIPTION:
; The driver's runtime state tables — ScriptInformation, the script/keyboard
; shortcut slot tables (SLOTS/LABELS/DEFAULTS/FALLBACKS/SEND_CODES + assignment
; maps) and CategoryEnabled — plus the readers that populate them from config
; (ReadCategoryEnabled, IsCategoryGated, ReadScriptConfig). Extracted verbatim
; from ErgoptiPlus.ahk (P4 entrypoint decomposition) and #Include'd in place, so
; the global assignments still run at the same point in the boot sequence and the
; reader functions (hoisted) stay available to their boot call sites.
; ==============================================================================

; feature_state.ahk is syntax-validated on its own as well as included after
; boot.ahk.  Do not dereference boot-owned path globals while constructing the
; declaration: their empty standalone values are harmless and the real driver
; has assigned both before this file executes.
global _FeatureStateConfigDir := IsSet(_ConfigDir) ? _ConfigDir : ""
global _FeatureStateAhkSubDir := IsSet(_AhkSubDir) ? _AhkSubDir : ""

global ScriptInformation := Map(
    "MagicKey", "★",
    ; Scancode and QWERTY character of the physical key remapped to ★.
    ; Defaults to SC02E / "j" (the J position on the Ergopti layout).
    ; QWERTY users or other layouts can override via [hotstrings] magic_key_source_scan
    ; and magic_key_source_char in config.toml.
    "MagicKeySourceScan", "SC02E",
    "MagicKeySourceChar", "j",
    ; Manual override for the AltGr-as-Kana / custom-remap detection. Default
    ; false here is overwritten by HotstringEngineInit() which auto-detects via
    ; a reverse VK_RMENU→SC probe. The TOML value (under [Script]) wins when
    ; explicitly set to "true" or "false"; "auto" (or absent) defers to the
    ; probe. Kept as an escape hatch in case the probe ever misfires on an
    ; exotic layout.
    "AltGrIsKanaRemap", "auto",
    ; Configurable file paths — all derived from _ConfigDir set above.
    ; AHK-specific files (.ahk, AHK config.toml) go under ``autohotkey/`` so
    ; the folder can be safely shared with the Hammerspoon driver via cloud
    ; sync. Shared neutral files (hotstrings TOML, personal info) stay
    ; at the root of _ConfigDir.
    "PersonalAhkPath", _FeatureStateConfigDir . _FeatureStateAhkSubDir . "personal_shortcuts.ahk",
    "PersonalTomlPath", _FeatureStateConfigDir . "hotstrings\personal_hotstrings.toml",
    "PersonalHotstringsDir", _FeatureStateConfigDir . "hotstrings\",
    "PersonalInfoTomlPath", _FeatureStateConfigDir . "personal_info.toml",
)

; Script-management hotkey slots. Each AltGr+key combo dispatches to an action
; from GESTURE_ACTIONS (see modules/gestures.ahk) so the user can re-purpose
; them via the tray menu the same way they configure trackpad gestures.
; ``Default`` is the action fired on a fresh install; ``Fallback`` is what we
; send to the OS when the assignment is "none" (so the underlying key keeps
; working). ``ScKey`` is the scancode of the secondary key for the GetKeyState
; double-check guarding against AltGr+Enter pause-bug-style misfires.
global SCRIPT_SHORTCUT_SLOTS := [
    "script_altgr_enter",
    "script_altgr_backspace",
    "script_altgr_delete",
    "script_altgr_escape",
]
global SCRIPT_SHORTCUT_LABELS := Map(
    "script_altgr_enter",     "sg_labels.script_altgr_enter",
    "script_altgr_backspace", "sg_labels.script_altgr_backspace",
    "script_altgr_delete",    "sg_labels.script_altgr_delete",
    "script_altgr_escape",    "sg_labels.script_altgr_escape",
)
global SCRIPT_SHORTCUT_DEFAULTS := Map(
    "script_altgr_enter", "script_pause_toggle",
    "script_altgr_backspace", "script_reload",
    "script_altgr_delete", "open_personal_shortcuts",
    "script_altgr_escape", "script_quit",
)
global SCRIPT_SHORTCUT_FALLBACKS := Map(
    "script_altgr_enter", "{Enter}",
    "script_altgr_backspace", "{BackSpace}",
    "script_altgr_delete", "{Delete}",
    "script_altgr_escape", "{Escape}",
)
global ScriptShortcutAssignments := Map()
for _FeatureStateIndex, _FeatureStateSlot in SCRIPT_SHORTCUT_SLOTS {
    ScriptShortcutAssignments[_FeatureStateSlot] := SCRIPT_SHORTCUT_DEFAULTS[_FeatureStateSlot]
}

; Configurable keyboard shortcuts — Ctrl/Win/Alt × a-z, 0-9 and special keys.
; Each slot id matches a GESTURE_ACTIONS key (e.g. "win_a", "ctrl_b").
; Defaults below mirror the legacy hard-coded shortcuts so a fresh install
; behaves identically to before while giving the user full control via the menu.
global KEYBOARD_SHORTCUT_DEFAULTS := Map(
    "win_a", "select_line",
    "win_d", "open_hotstrings_editor",
    "win_g", "open_url",
    "win_c", "ocr_screenshot",
    "win_h", "screen_capture",
    "win_m", "activity_simulation",
    "win_n", "take_note",
    "win_o", "surround_parens",
    "win_s", "search_web",
    "win_t", "teleport_mouse",
    "win_u", "uppercase_selection",
    "win_w", "titlecase_selection",
    "win_x", "pick_color",
    "ctrl_b", "microsoft_bold",
    "ctrl_shift_v", "paste_plain",
)
; AHK send-key codes for each slot — must match GESTURE_ACTIONS Fn lambdas.
; Slots not listed here are generated dynamically from their suffix.
global KEYBOARD_SHORTCUT_SEND_CODES := Map(
    "ctrl_shift_v", "^+v",
)
global KeyboardShortcutAssignments := Map()

; ParseTomlFile / IniCacheGet / ResolveConfigPath are defined in lib/ini_helpers.ahk
; (included above) so the test runner can exercise them in isolation.

; Category-level gating state (master-toggle refactor).
;
; The master toggle at the top of every category submenu ("Activer la
; disposition" / "Désactiver les raccourcis" / ...) used to flip every
; individual feature in the category to the same value, destroying the
; user's per-feature choices on every master click. The new design
; separates the master gate (this Map) from the per-feature .Enabled
; flags: toggling the master flips ``CategoryEnabled[Category]`` only,
; and ``ApplyMasterGatesToFeatures`` in lib/master_gates.ahk forces
; the corresponding Features entries to false at boot — a disabled
; category propagates as all Features entries reading false at the HotIf
; level, but the underlying per-feature choices persisted on disk are
; preserved for when the user re-enables the master.
;
; Defaults all true so a fresh install (or a user who hasn't touched
; the master) sees no behavior change. Loaded from the [CategoryEnabled]
; section of config.toml; default-on when the section is absent.
global CategoryEnabled := Map(
    "Layout",     true,
    "Shortcuts",  true,
    "Hotstrings", true,
    "TapHolds",   true,
    ; Per-TOML-file hotstring sub-category gates. Independent of the top
    ; Hotstrings master above: a category file can be switched off while the
    ; rest of the hotstrings stay live. The parent menu checkmark for each
    ; category follows ITS gate (not whether every section is checked), and
    ; ApplyMasterGatesToFeatures zeroes only that category's features when off.
    ; Default on so existing configs and fresh installs are unchanged.
    "Autocorrection",     true,
    "DistancesReduction", true,
    "SFBsReduction",      true,
    "Rolls",              true,
    "MagicKey",           true,
)

ReadCategoryEnabled(Cache) {
    global CategoryEnabled
    for Category, _Default in CategoryEnabled {
        Raw := _FeatureStateIniGet(Cache, "ahk.category_enabled", _FeatureStateCategoryKey(Category))
        if (Raw == "_") {
            continue
        }
        CategoryEnabled[Category] := (Raw == true or Raw == 1 or Raw == "1" or Raw == "true")
    }
}

; Returns true when the master gate for ``Category`` is on. Used by
; the mirrors (to apply gating when populating Features) and by the
; tray-menu rendering (to label the master toggle and parent menu).
IsCategoryGated(Category) {
    global CategoryEnabled
    if !CategoryEnabled.Has(Category) {
        try LoggerWarn("MasterGates", "IsCategoryGated: unknown category '{1}' — defaulting to gated.", Category)
        return true
    }
    return CategoryEnabled[Category]
}

ReadScriptConfig(Cache) {
    ; MagicKey lives in [hotstrings] trigger_char in the v2 TOML.
    Raw := _FeatureStateIniGet(Cache, "hotstrings", "trigger_char")
    if Raw != "_"
        ScriptInformation["MagicKey"] := Raw
    ; Source key for the J→★ remap — scancode and QWERTY character are stored
    ; separately so the remapping works regardless of the active OS layout.
    RawScan := _FeatureStateIniGet(Cache, "hotstrings", "magic_key_source_scan")
    if RawScan != "_"
        ScriptInformation["MagicKeySourceScan"] := RawScan
    RawChar := _FeatureStateIniGet(Cache, "hotstrings", "magic_key_source_char")
    if RawChar != "_"
        ScriptInformation["MagicKeySourceChar"] := RawChar
    ; AltGr-as-Kana manual override. Default "auto" defers to the reverse
    ; VK_RMENU→SC probe in HotstringEngineInit(); "true" / "false" force the
    ; respective mode. Lives in [script] so the user can lock it once per
    ; machine if auto-detection misfires on an exotic layout.
    RawKana := _FeatureStateIniGet(Cache, "script", "alt_gr_is_kana_remap")
    if RawKana != "_"
        ScriptInformation["AltGrIsKanaRemap"] := RawKana
    ; Restore the engine-level repeat-key toggle (defaults to enabled when absent).
    global HSE_RepeatEnabled
    RawRepeat := _FeatureStateIniGet(Cache, "hotstrings", "repeat_key_enabled")
    if RawRepeat != "_"
        HSE_RepeatEnabled := (RawRepeat == "1" or RawRepeat == "true")
    ; Paths are always derived from _ConfigDir at startup and are never persisted.
}

; IniCacheGet belongs to the configuration-loader boundary. Resolve it at call
; time so this state-only module remains warning-clean when syntax-validated
; outside the driver's full include graph, while preserving the one canonical
; parser/cache implementation at runtime.
_FeatureStateIniGet(Cache, Section, Key) {
    try return Func("IniCacheGet").Call(Cache, Section, Key)
    catch as Err
        throw Error("feature_state requires IniCacheGet from the configuration loader: " . Err.Message)
}

; Category-key normalization is owned by config_io.ahk. Keep the state module
; independent from that later include at parse time without creating a second
; mapping that could drift from persisted configuration.
_FeatureStateCategoryKey(Category) {
    try return Func("_CategoryEnabledKey").Call(Category)
    catch as Err
        throw Error("feature_state requires _CategoryEnabledKey from config_io.ahk: " . Err.Message)
}
