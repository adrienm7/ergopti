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
    if (A_Args.Length != 1)
        throw Error("expected exactly one startup fixture name")
    switch A_Args[1] {
        case "parsed":
            _FeatureStateSmokeParsedConfig()
        case "missing":
            _FeatureStateSmokeMissingSections()
		case "neutral":
			_FeatureStateSmokeNeutral()
		case "neutral_first_boot":
			_FeatureStateSmokeNeutralFirstBoot()
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
		case "invalid_source_scan":
			_FeatureStateSmokeInvalidValue("hotstrings", "magic_key_source_scan", "not-a-scan")
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
        FileAppend('[hotstrings]`ntrigger_char = "@"`nmagic_key_source_scan = "SC031"`nmagic_key_source_char = "n"`nrepeat_key_enabled = false`n[script]`nalt_gr_is_kana_remap = true`n[category_enabled]`nhotstrings = false`n', TempConfig, "UTF-8")
        Cache := ParseTomlFile(TempConfig)
        ReadScriptConfig(Cache)
        ReadCategoryEnabled(Cache)
    } finally {
        try FileDelete(TempConfig)
    }
    _FeatureStateSmokeAssert("@", ScriptInformation["MagicKey"], "trigger_char")
    _FeatureStateSmokeAssert("SC031", ScriptInformation["MagicKeySourceScan"], "magic_key_source_scan")
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
	for Category, Enabled in CategoryEnabled
		_FeatureStateSmokeAssert(false, Enabled, "empty master: " . Category)
	CategoryEnabled.Delete("Hotstrings")
	_FeatureStateSmokeAssert(false, IsCategoryGated("Hotstrings"), "missing master stays neutral")
	_FeatureStateSmokeAssert(false, IsCategoryGated("Personal"), "missing inherited master stays neutral")
	CategoryEnabled["Hotstrings"] := true
	_FeatureStateSmokeAssert(true, IsCategoryGated("Personal"), "explicit inherited master remains enabled")
	for Slot, Action in ScriptShortcutAssignments
		_FeatureStateSmokeAssert("none", Action, "empty script shortcut: " . Slot)
	for Slot, Action in KEYBOARD_SHORTCUT_DEFAULTS
		_FeatureStateSmokeAssert("none", Action, "empty keyboard shortcut: " . Slot)
	_FeatureStateSmokeAssert(false, ScriptInformation["AltGrIsKanaRemap"], "empty layout remap")
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
		_FeatureStateRequireManifestDefault("hotstrings.magic_key_source_scan"),
		ScriptInformation["MagicKeySourceScan"], "manifest source scan default")
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

_FeatureStateSmokeInvalidCategory(Value) {
	ReadCategoryEnabled(Map("category_enabled", Map("hotstrings", Value)))
}

_FeatureStateSmokeAssert(Expected, Actual, Label) {
    if (Expected != Actual)
        throw Error(Label . ": expected " . Expected . ", got " . Actual)
}
