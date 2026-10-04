; static/ergopti_plus/windows/tests/support/feature_state_boot_smoke.ahk

; ============================================================================
; MODULE: Feature-State Boot Smoke Harness
; DESCRIPTION:
; Runs the real configuration reader in a separate AutoHotkey process with the
; same include order as ErgoptiPlus.ahk.  It deliberately does not use the
; test-runner stubs: a boot-time dependency or function-resolution failure must
; make this child process return a non-zero exit code.
; ============================================================================

#Requires AutoHotkey v2.0+
#SingleInstance Off
#NoTrayIcon
SetWorkingDir(A_ScriptDir)
#Warn All, StdOut
#Warn VarUnset, Off

; Initialization failures must fail the headless harness instead of opening a
; modal dialog before the fixture's own exception boundary is reached.
_FeatureStateSmokeFatal(Err, Mode) {
	FileAppend("feature-state initialization failed: " . Err.Message . "`n" . Err.Stack . "`n", "*")
	ExitApp(1)
	return 1
}
OnError(_FeatureStateSmokeFatal)

; The feature-state module derives these paths at include time in production.
global _ConfigDir := A_Temp . "\ergopti_feature_state_boot\"
global _AhkSubDir := ""
global _DriverDir := A_ScriptDir . "\..\.."
global _SharedDir := A_ScriptDir . "\..\..\..\_shared"
global HSE_RepeatEnabled := true

; This is the production boot dependency order: canonical config helpers,
; feature state, then the later-declared category-key normalizer.
#Include ..\..\infra\toml\toml_helpers.ahk
#Include ..\..\infra\manifest_reader.ahk
#Include ..\..\infra\feature_state.ahk
#Include ..\..\infra\config_io.ahk
#Include ..\..\infra\first_boot.ahk

try {
    if (A_Args.Length != 1 && !(A_Args.Length == 3 && A_Args[1] == "distance_gate"))
        throw Error("expected exactly one startup fixture name")
    switch A_Args[1] {
        case "distance_gate":
			ReadCategoryEnabled(TOML_ParseFreshFile(A_Args[2]))
			if CategoryEnabled["DistancesReduction"] != (A_Args[3] == "true")
				throw Error("The native distance gate differs from the saved preference.")
        case "parsed":
            _FeatureStateSmokeParsedConfig()
        case "missing":
            _FeatureStateSmokeMissingSections()
		case "neutral":
			_FeatureStateSmokeNeutral()
		case "neutral_first_boot":
			_FeatureStateSmokeNeutralFirstBoot()
		case "script_none":
			_FeatureStateSmokeScriptNone()
		case "manifest_defaults":
			_FeatureStateSmokeManifestDefaults()
        case "malformed":
            _FeatureStateSmokeMalformedCache()
        case "non_map":
            _FeatureStateSmokeNonMapCache()
        case "empty_trigger":
            _FeatureStateSmokeInvalidTrigger("")
        case "long_trigger":
            _FeatureStateSmokeInvalidTrigger("abcde")
        case "multi_trigger":
            _FeatureStateSmokeInvalidTrigger("ab")
        case "unicode_trigger":
            _FeatureStateSmokeValidUnicodeTrigger()
		case "invalid_repeat_number":
			_FeatureStateSmokeInvalidValue("hotstrings", "repeat_key_enabled", 2)
		case "invalid_repeat_string":
			_FeatureStateSmokeInvalidValue("hotstrings", "repeat_key_enabled", "false")
		case "invalid_kana":
			_FeatureStateSmokeInvalidValue("script", "alt_gr_is_kana_remap", "sometimes")
		case "outdated_source_key":
			_FeatureStateSmokeOutdatedSourceKey()
		case "retired_source_scan":
			_FeatureStateSmokeRetiredSourceScan()
		case "invalid_source_char":
			_FeatureStateSmokeInvalidValue("hotstrings", "magic_key_source_char", "two")
		case "invalid_category_string":
			_FeatureStateSmokeInvalidCategory("true")
		case "invalid_category_number":
			_FeatureStateSmokeInvalidCategory(2)
        default:
            throw Error("unknown startup fixture: " . A_Args[1])
    }
} catch as Err {
    try FileAppend("feature-state boot smoke failed: " . Err.Message . "`n" . Err.Stack . "`n", "*")
    ExitApp(1)
}
ExitApp(0)

_FeatureStateSmokeParsedConfig() {
    global ScriptInformation, CategoryEnabled, HSE_RepeatEnabled
    TempConfig := A_Temp . "\ergopti_feature_state_boot_" . DllCall("GetCurrentProcessId") . ".toml"
    try {
        try FileDelete(TempConfig)
        FileAppend('[hotstrings]`ntrigger_char = "@"`nmagic_key_source = "KeyN"`nmagic_key_source_char = "n"`nrepeat_key_enabled = false`n[script]`nalt_gr_is_kana_remap = true`n[category_enabled]`nhotstrings = false`n', TempConfig, "UTF-8")
        Cache := ParseTomlFile(TempConfig)
        ReadScriptConfig(Cache)
        ReadCategoryEnabled(Cache)
    } finally {
        try FileDelete(TempConfig)
    }
    _FeatureStateSmokeAssert("@", ScriptInformation["MagicKey"], "trigger_char")
    _FeatureStateSmokeAssert("KeyN", ScriptInformation["MagicKeySource"], "magic_key_source")
    _FeatureStateSmokeAssert(true, ScriptInformation["MagicKeySourceChosen"], "a named source key is a choice")
    _FeatureStateSmokeAssert("n", ScriptInformation["MagicKeySourceChar"], "magic_key_source_char")
    _FeatureStateSmokeAssert(true, ScriptInformation["AltGrIsKanaRemap"], "alt_gr_is_kana_remap")
    _FeatureStateSmokeAssert(false, HSE_RepeatEnabled, "repeat_key_enabled")
    _FeatureStateSmokeAssert(false, CategoryEnabled["Hotstrings"], "category_enabled.hotstrings")
}

_FeatureStateSmokeMissingSections() {
    global ScriptInformation, CategoryEnabled, HSE_RepeatEnabled
    DefaultMagicKey := ScriptInformation["MagicKey"]
    ReadScriptConfig(Map())
    ReadCategoryEnabled(Map())
    _FeatureStateSmokeAssert(DefaultMagicKey, ScriptInformation["MagicKey"], "missing hotstrings default")
    _FeatureStateSmokeAssert(false, HSE_RepeatEnabled, "missing repeat_key_enabled default")
    _FeatureStateSmokeAssert(false, CategoryEnabled["Hotstrings"], "missing category default")
}

_FeatureStateSmokeNeutral() {
	global ScriptInformation, CategoryEnabled, ScriptShortcutAssignments, KEYBOARD_SHORTCUT_DEFAULTS, HSE_RepeatEnabled
	ReadScriptConfig(Map())
	ReadCategoryEnabled(Map())
	_FeatureStateSmokeAssert(false, HSE_RepeatEnabled, "empty repeat-key fallback")
	for Category, Enabled in CategoryEnabled {
		; The key-combinations gate only narrows its families, whose own switches
		; are off here, so its open neutral value activates nothing.
		if (Category == "KeyCombinations")
			continue
		_FeatureStateSmokeAssert(false, Enabled, "empty master: " . Category)
	}
	_FeatureStateSmokeAssert(true, CategoryEnabled["KeyCombinations"], "empty key-combinations sub-gate stays open")
	CategoryEnabled.Delete("Hotstrings")
	_FeatureStateSmokeAssert(false, IsCategoryGated("Hotstrings"), "missing master stays neutral")
	_FeatureStateSmokeAssert(false, IsCategoryGated("Personal"), "missing inherited master stays neutral")
	CategoryEnabled["Hotstrings"] := true
	_FeatureStateSmokeAssert(true, IsCategoryGated("Personal"), "explicit inherited master remains enabled")
	; The script-management chords are the declared exception: an empty
	; configuration starts them with their preset (maintainer decision of
	; 2026-09-30, manifest active_by_default).
	AssertedScriptSlots := 0
	for Slot, Action in ScriptShortcutAssignments {
		_FeatureStateSmokeAssert(ManifestRecommendedFor("shortcuts.script_control." . Slot), Action,
			"empty script shortcut starts with its preset: " . Slot)
		if (Action == "none")
			throw Error("empty script shortcut " . Slot . " runs no action")
		AssertedScriptSlots += 1
	}
	_FeatureStateSmokeAssert(4, AssertedScriptSlots, "the four script shortcut slots")
	; The contextual editor is an ordinary declared default behind the closed
	; Shortcuts master. Its presence does not authorize a native binding at boot.
	_FeatureStateSmokeAssert(false, CategoryEnabled["Shortcuts"], "empty shortcut master remains closed")
	AssertedContextual := 0
	for Slot, Action in KEYBOARD_SHORTCUT_DEFAULTS {
		if Slot == "magic_editor" {
			_FeatureStateSmokeAssert("open_hotstrings_editor", Action, "the declared contextual editor default")
			_FeatureStateSmokeAssert(ManifestDefaultFor("shortcuts.keyboard.magic_editor"), Action,
				"the contextual default comes from its actual manifest owner")
			AssertedContextual += 1
		} else {
			_FeatureStateSmokeAssert("none", Action, "empty keyboard shortcut: " . Slot)
		}
	}
	_FeatureStateSmokeAssert(1, AssertedContextual, "exactly one contextual default remains inert behind its master")
	; Not an activation: "auto" lets the layout's own probe name the AltGr key.
	; A neutral false forced the standard family on every Kana-style layout.
	_FeatureStateSmokeAssert("auto", ScriptInformation["AltGrIsKanaRemap"], "empty layout remap")
}

; A config.toml that names "none" for a script slot keeps that chord off now
; that an absent slot starts with its preset (maintainer decision 2026-09-30).
_FeatureStateSmokeScriptNone() {
	global ScriptShortcutAssignments, _IniCache
	TempConfig := A_Temp . "\ergopti_script_none_" . DllCall("GetCurrentProcessId") . ".toml"
	try {
		try FileDelete(TempConfig)
		FileAppend('[shortcuts.script_control]`nscript_altgr_enter = "none"`n', TempConfig, "UTF-8")
		_IniCache := ParseTomlFile(TempConfig)
		ReadScriptShortcutsConfig()
	} finally {
		try FileDelete(TempConfig)
	}
	_FeatureStateSmokeAssert("none", ScriptShortcutAssignments["script_altgr_enter"],
		"an explicit none keeps the chord off")
	for Slot in ["script_altgr_backspace", "script_altgr_delete", "script_altgr_escape"]
		_FeatureStateSmokeAssert(ManifestRecommendedFor("shortcuts.script_control." . Slot),
			ScriptShortcutAssignments[Slot], "an absent slot starts with its preset: " . Slot)
}

_FeatureStateSmokeNeutralFirstBoot() {
	global _ConfigDir
	_ConfigDir := A_Temp . "\ergopti_neutral_first_boot_" . DllCall("GetCurrentProcessId") . "\"
	try {
		EnsureUserConfigsExist()
		if FileExist(_ConfigDir . "autohotkey\tap_hold.toml")
			throw Error("first boot imported the recommended tap-hold preset")
		if FileExist(_ConfigDir . "autohotkey\config.toml")
			throw Error("first boot persisted neutral defaults as explicit overrides")
	} finally {
		for Name in ["tap_hold.toml", "config.toml"]
			try FileDelete(_ConfigDir . "autohotkey\" . Name)
		try DirDelete(_ConfigDir . "autohotkey")
		try DirDelete(_ConfigDir)
	}
}

_FeatureStateSmokeManifestDefaults() {
	global ScriptInformation
	_FeatureStateSmokeAssert(
		_FeatureStateRequireManifestDefault("hotstrings.trigger_char"),
		ScriptInformation["MagicKey"], "manifest trigger default")
	_FeatureStateSmokeAssert(
		_FeatureStateRequireManifestDefault("hotstrings.magic_key_source"),
		ScriptInformation["MagicKeySource"], "manifest source key default")
	_FeatureStateSmokeAssert(false, ScriptInformation["MagicKeySourceChosen"],
		"the manifest default leaves the source key to the layout")
	_FeatureStateSmokeAssert(
		_FeatureStateRequireManifestDefault("hotstrings.magic_key_source_char"),
		ScriptInformation["MagicKeySourceChar"], "manifest source character default")
}

_FeatureStateSmokeMalformedCache() {
    global ScriptInformation, CategoryEnabled, HSE_RepeatEnabled
    DefaultMagicKey := ScriptInformation["MagicKey"]
    Cache := Map("hotstrings", true, "script", 1, "category_enabled", false)
    ReadScriptConfig(Cache)
    ReadCategoryEnabled(Cache)
    _FeatureStateSmokeAssert(DefaultMagicKey, ScriptInformation["MagicKey"], "malformed hotstrings default")
    _FeatureStateSmokeAssert(false, HSE_RepeatEnabled, "malformed repeat_key_enabled default")
    _FeatureStateSmokeAssert(false, CategoryEnabled["Hotstrings"], "malformed category default")
}

_FeatureStateSmokeNonMapCache() {
    global ScriptInformation, CategoryEnabled, HSE_RepeatEnabled
    DefaultMagicKey := ScriptInformation["MagicKey"]
    ReadScriptConfig("not-a-cache")
    ReadCategoryEnabled("not-a-cache")
    _FeatureStateSmokeAssert(DefaultMagicKey, ScriptInformation["MagicKey"], "non-Map hotstrings default")
    _FeatureStateSmokeAssert(false, HSE_RepeatEnabled, "non-Map repeat_key_enabled default")
    _FeatureStateSmokeAssert(false, CategoryEnabled["Hotstrings"], "non-Map category default")
}

_FeatureStateSmokeInvalidTrigger(Value) {
	Cache := Map("hotstrings", Map("trigger_char", Value))
	ReadScriptConfig(Cache)
}

_FeatureStateSmokeValidUnicodeTrigger() {
	global ScriptInformation
	Value := Chr(0x1F642)
	ReadScriptConfig(Map("hotstrings", Map("trigger_char", Value)))
	_FeatureStateSmokeAssert(Value, ScriptInformation["MagicKey"],
		"single-code-point Unicode trigger")
}

_FeatureStateSmokeInvalidValue(Section, Key, Value) {
	ReadScriptConfig(Map(Section, Map(Key, Value)))
}

; An outdated source key is reported by the loader and offered by the cleanup:
; here it reads as the automatic key, it never aborts the boot. The loader's
; case-insensitive enum rule is followed, in the manifest's spelling.
_FeatureStateSmokeOutdatedSourceKey() {
	global ScriptInformation
	for Value in ["SC03B", "not-a-key", 46, ""] {
		ReadScriptConfig(Map("hotstrings", Map("magic_key_source", Value)))
		_FeatureStateSmokeAssert("auto", ScriptInformation["MagicKeySource"], "outdated source key")
		_FeatureStateSmokeAssert(false, ScriptInformation["MagicKeySourceChosen"], "outdated source key choice")
	}
	ReadScriptConfig(Map("hotstrings", Map("magic_key_source", "keyj")))
	; _FeatureStateSmokeAssert compares with the case-insensitive !=.
	if (ScriptInformation["MagicKeySource"] !== "KeyJ")
		throw Error("loader-accepted spelling: expected KeyJ, got " . ScriptInformation["MagicKeySource"])
	_FeatureStateSmokeAssert(true, ScriptInformation["MagicKeySourceChosen"], "loader-accepted choice")
}

; The Windows-only scan code was renamed by config schema v5: the reader drops
; the old spelling at once, so a file the migration did not reach chooses nothing.
_FeatureStateSmokeRetiredSourceScan() {
	global ScriptInformation
	ReadScriptConfig(Map("hotstrings", Map("magic_key_source_scan", "SC031")))
	_FeatureStateSmokeAssert("auto", ScriptInformation["MagicKeySource"], "retired scan code")
	_FeatureStateSmokeAssert(false, ScriptInformation["MagicKeySourceChosen"], "retired scan code choice")
}

_FeatureStateSmokeInvalidCategory(Value) {
	ReadCategoryEnabled(Map("category_enabled", Map("hotstrings", Value)))
}

_FeatureStateSmokeAssert(Expected, Actual, Label) {
    if (Expected != Actual)
        throw Error(Label . ": expected " . Expected . ", got " . Actual)
}
