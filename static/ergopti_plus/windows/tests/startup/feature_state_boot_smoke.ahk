; static/ergopti_plus/windows/tests/startup/feature_state_boot_smoke.ahk

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

; The feature-state module derives these paths at include time in production.
global _ConfigDir := A_Temp . "\ergopti_feature_state_boot\"
global _AhkSubDir := ""
global HSE_RepeatEnabled := true

; This is the production boot dependency order: canonical config helpers,
; feature state, then the later-declared category-key normalizer.
#Include ..\..\infra\toml\toml_helpers.ahk
#Include ..\..\infra\feature_state.ahk
#Include ..\..\infra\config_io.ahk

try {
    if (A_Args.Length != 1)
        throw Error("expected exactly one startup fixture name")
    switch A_Args[1] {
        case "parsed":
            _FeatureStateSmokeParsedConfig()
        case "missing":
            _FeatureStateSmokeMissingSections()
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
    _FeatureStateSmokeAssert(true, HSE_RepeatEnabled, "missing repeat_key_enabled default")
    _FeatureStateSmokeAssert(true, CategoryEnabled["Hotstrings"], "missing category default")
}

_FeatureStateSmokeMalformedCache() {
    global ScriptInformation, CategoryEnabled, HSE_RepeatEnabled
    DefaultMagicKey := ScriptInformation["MagicKey"]
    Cache := Map("hotstrings", true, "script", 1, "category_enabled", false)
    ReadScriptConfig(Cache)
    ReadCategoryEnabled(Cache)
    _FeatureStateSmokeAssert(DefaultMagicKey, ScriptInformation["MagicKey"], "malformed hotstrings default")
    _FeatureStateSmokeAssert(true, HSE_RepeatEnabled, "malformed repeat_key_enabled default")
    _FeatureStateSmokeAssert(true, CategoryEnabled["Hotstrings"], "malformed category default")
}

_FeatureStateSmokeNonMapCache() {
    global ScriptInformation, CategoryEnabled, HSE_RepeatEnabled
    DefaultMagicKey := ScriptInformation["MagicKey"]
    ReadScriptConfig("not-a-cache")
    ReadCategoryEnabled("not-a-cache")
    _FeatureStateSmokeAssert(DefaultMagicKey, ScriptInformation["MagicKey"], "non-Map hotstrings default")
    _FeatureStateSmokeAssert(true, HSE_RepeatEnabled, "non-Map repeat_key_enabled default")
    _FeatureStateSmokeAssert(true, CategoryEnabled["Hotstrings"], "non-Map category default")
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

_FeatureStateSmokeAssert(Expected, Actual, Label) {
    if (Expected != Actual)
        throw Error(Label . ": expected " . Expected . ", got " . Actual)
}
