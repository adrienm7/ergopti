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
#Include ..\..\adapters\file_system.ahk
#Include ..\..\adapters\key_state.ahk
#Include ..\..\infra\toml\toml_helpers.ahk
#Include ..\..\infra\manifest_reader.ahk
#Include ..\..\infra\feature_state.ahk
; A second ordinary include must not reset the already published data owner.
TapKeyAssignments["feature_state_include_once_probe"] := "none"
#Include ..\..\infra\tap_keys.ahk
#Include ..\..\infra\config_io.ahk
#Include ..\..\infra\first_boot.ahk

try {
    if (A_Args.Length != 1 && !(A_Args.Length == 3 && A_Args[1] == "distance_gate")
			&& !(A_Args.Length == 2 && A_Args[1] == "persisted_semantic"))
        throw Error("expected exactly one startup fixture name")
    switch A_Args[1] {
		case "tap_binding_publication":
			_FeatureStateSmokeTapBindingPublication()
		case "persisted_semantic":
			_FeatureStateSmokePersistedSemantic(A_Args[2])
        case "distance_gate":
			ReadCategoryEnabled(TOML_ParseFreshFile(A_Args[2]))
			if CategoryEnabled["DistancesReduction"] != (A_Args[3] == "true")
				throw Error("The native distance gate differs from the saved preference.")
        case "parsed":
            _FeatureStateSmokeParsedConfig()
		case "semantic_root":
			_FeatureStateSmokeSemanticConfig(true)
		case "semantic_inline":
			_FeatureStateSmokeSemanticConfig("inline")
		case "semantic_section":
			_FeatureStateSmokeSemanticConfig(false)
        case "missing":
            _FeatureStateSmokeMissingSections()
		case "neutral":
			_FeatureStateSmokeNeutral()
		case "neutral_first_boot":
			_FeatureStateSmokeNeutralFirstBoot()
		case "script_none":
			_FeatureStateSmokeScriptNone()
		case "script_binding_publication":
			_FeatureStateSmokeScriptBindingPublication()
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
        Cache := ParseConfigTomlFile(TempConfig)
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

; Independent complete source spellings reach the actual native bootstrap readers.
_FeatureStateSmokeSemanticConfig(Root) {
	global ScriptInformation, CategoryEnabled, HSE_RepeatEnabled
	TempConfig := A_Temp . "\ergopti_feature_state_semantic_" . DllCall("GetCurrentProcessId") . ".toml"
	Source := Root
		? 'hotstrings.trigger_char = "@"`nhotstrings.magic_key_source = "KeyN"`nhotstrings.magic_key_source_char = "n"`nhotstrings.repeat_key_enabled = true`nscript.alt_gr_is_kana_remap = true`ncategory_enabled.hotstrings = true`n'
		: '[hotstrings]`ntrigger_char = "@"`nmagic_key_source = "KeyN"`nmagic_key_source_char = "n"`nrepeat_key_enabled = true`n[script]`nalt_gr_is_kana_remap = true`n[category_enabled]`nhotstrings = true`n'
	if Root == "inline"
		Source := 'hotstrings = { trigger_char = "@", magic_key_source = "KeyN", magic_key_source_char = "n", repeat_key_enabled = true }`nscript = { alt_gr_is_kana_remap = true }`ncategory_enabled = { hotstrings = true }`n'
	try {
		FileAppend(Source, TempConfig, "UTF-8")
		Cache := ParseConfigTomlFile(TempConfig)
		ReadScriptConfig(Cache)
		ReadCategoryEnabled(Cache)
		_FeatureStateSmokeAssert("@", ScriptInformation["MagicKey"], "semantic trigger_char")
		_FeatureStateSmokeAssert("KeyN", ScriptInformation["MagicKeySource"], "semantic source key")
		_FeatureStateSmokeAssert("n", ScriptInformation["MagicKeySourceChar"], "semantic source character")
		_FeatureStateSmokeAssert(true, ScriptInformation["AltGrIsKanaRemap"], "semantic Kana override")
		_FeatureStateSmokeAssert(true, HSE_RepeatEnabled, "semantic repeat key")
		_FeatureStateSmokeAssert(true, CategoryEnabled["Hotstrings"], "semantic master gate")
	} finally {
		try FileDelete(TempConfig)
	}
}


; Reads the parent test's actual saved file without creating a replacement seed.
_FeatureStateSmokePersistedSemantic(Path) {
	global ScriptInformation, _ConfigBootReadFailed
	if !FileExist(Path)
		throw Error("The actual semantic publication is absent")
	Before := FileRead(Path, "UTF-8")
	Cache := ParseConfigTomlFile(Path)
	if _ConfigBootReadFailed
		throw Error("The actual saved semantic source was refused at boot")
	ReadScriptConfig(Cache)
	_FeatureStateSmokeAssert("@", ScriptInformation["MagicKey"], "durable dotted trigger")
	Names := IniCacheGet(Cache, "hotstrings.autocorrection", "names")
	if !(Names is Map) || Names.Count != 3
		throw Error("The actual declared inline feature record must retain all three source children")
	_FeatureStateSmokeAssert("_", IniCacheGet(Cache, "hotstrings.autocorrection.names", "time_activation_seconds"),
		"a declared record is not a flattened child section")
	Timing := Names["time_activation_seconds"]
	if !(Timing is Float) || Timing != 0.75
		throw Error("The durable inline timing must remain the exact native Float")
	Value := Names["enabled"]
	if !(Value is String) || StrCompare(Value, "true", true) != 0
		throw Error("The obsolete inline scalar must remain text in the retained source")
	_FeatureStateSmokeAssert("retain", Names["future"], "durable foreign child")
	if StrCompare(Before, FileRead(Path, "UTF-8"), true) != 0
		throw Error("A bootstrap read changed the actual durable source")
}


; This receipt is produced by the actual compiled feature-state declaration.
_FeatureStateSmokeScriptBindingPublication() {
	global SCRIPT_SHORTCUT_SLOTS, _ScriptShortcutBindingPublication
	if _ScriptShortcutBindingPublication.Source != SCRIPT_SHORTCUT_SLOTS
		throw Error("The compiled script publication lost its source declaration identity")
	Catalogue := _ScriptShortcutBindingPublication.Catalogue
	if Catalogue["prefix"] !== "script__" || Catalogue["slots"].Count != 4 || Catalogue["slots"].CaseSense != "On"
		throw Error("The compiled script publication is not a complete case-exact domain")
	for Slot in ["script_altgr_enter", "script_altgr_backspace", "script_altgr_delete", "script_altgr_escape"] {
		if ConfigBindingIdentityScriptStatus("script__" . Slot, Catalogue) != "current"
			throw Error("The compiled publication lost the actual native slot " . Slot)
	}
	if ConfigBindingIdentityScriptStatus("script__removed_script_slot", Catalogue) != "retired"
		throw Error("The compiled publication did not judge an obsolete native script identity")
}

; Actual feature-state publication precedes configuration readers in this child.
_FeatureStateSmokeTapBindingPublication() {
	global TAP_KEY_ORDER, TAP_KEY_SCANCODES, _TapKeyBindingPublication, TapKeyAssignments
	if !TapKeyAssignments.Has("feature_state_include_once_probe")
		throw Error("An ordinary repeated include reinitialized the data owner")
	if _TapKeyBindingPublication.Source != TAP_KEY_ORDER || _TapKeyBindingPublication.ScanSource != TAP_KEY_SCANCODES
		throw Error("The compiled tap publication lost its actual source identities")
	Catalogue := _TapKeyBindingPublication.Catalogue
	if Catalogue["prefix"] !== "tap_key__" || Catalogue["slots"].Count != TAP_KEY_ORDER.Length
		|| Catalogue["slots"].CaseSense != "On"
		throw Error("The compiled tap publication is not a complete case-exact domain")
	for Slot in TAP_KEY_ORDER {
		if !Catalogue["slots"].Has(Slot) || _TapKeyBindingPublication.Scans[Slot] != TAP_KEY_SCANCODES[Slot]
			throw Error("The actual scan and order declaration diverged")
	}
	if ConfigBindingIdentityTapStatus("tap_key__removed_tap_key", Catalogue) != "retired"
		throw Error("The actual startup publication cannot identify a retired tap key")
}
