; tests/unit/test_hotkey_registrar_modifier_keys.ahk

; ==============================================================================
; MODULE: No registrar client binds a modifier key by name
; DESCRIPTION:
; A hotkey named by a modifier key ("RAlt", "RCtrl", "LControl", "vkA5") is its
; own AutoHotkey identity, hooked on that modifier's standard scan code. While
; it exists, even Off or under an ineligible #HotIf, AutoHotkey does not fall
; back to the scan-code hotkeys of the same key, so the tap-hold on that key
; stops firing (project-ahk-modifier-name-hotkey-shadows-scan-code). The chord
; grammar only rejects the neutral modifier names, so a metrics or keyboard
; shortcut such as "ralt" or "ctrl+rctrl" reached Hotkey() through the shared
; registrar; only the LLM trigger refused them. The registrar now refuses them
; for every client, and the metrics prompt tells the user why
; (registrar-modifier-key-2026-09-25).
; ==============================================================================

#Requires AutoHotkey v2.0

global _HRMK_MODIFIER_KEYS := ["lctrl", "rctrl", "lcontrol", "rcontrol", "lalt", "ralt",
	"lshift", "rshift", "lwin", "rwin", "vk10", "vk11", "vk12", "vk5b", "vk5c",
	"vka0", "vka1", "vka2", "vka3", "vka4", "vka5", "vka5sc138", "RAlt", "LControl"]
global _HRMK_NativeCalls := []

_HRMK_Hotkey(Name, Action := unset, Options := unset) {
	global _HRMK_NativeCalls
	_HRMK_NativeCalls.Push(Name)
	return true
}

_HRMK_NativeSpecRefusesEveryModifierKey() {
	global _HRMK_MODIFIER_KEYS
	for _, Key in _HRMK_MODIFIER_KEYS {
		AssertEqual("", HotkeyRegistrarNativeSpec([], Key),
			"a hotkey on the modifier key '" . Key . "' shadows the tap-hold scan-code hotkeys of that key")
		AssertEqual("", HotkeyRegistrarNativeSpec(["ctrl"], Key),
			"a chord ending in the modifier key '" . Key . "' is the same identity")
		AssertTrue(HotkeyRegistrarKeyIsModifier(Key), Key . " must be recognized as a modifier key")
	}
	AssertEqual("^m", HotkeyRegistrarNativeSpec(["ctrl"], "m"), "an ordinary key stays bindable")
	AssertEqual("^SC138", HotkeyRegistrarNativeSpec(["ctrl"], "sc138"),
		"a scan-code key joins the tap-hold's own identity instead of shadowing it")
	AssertFalse(HotkeyRegistrarKeyIsModifier("vk41"), "vk41 is the A key")
}
Test("hotkey registrar: a modifier key named as the chord key is refused (registrar-modifier-key-2026-09-25)",
	_HRMK_NativeSpecRefusesEveryModifierKey)

_HRMK_EveryClientRefusesAModifierKey() {
	global _HRMK_NativeCalls
	AssertEqual("", MS_ToAhkSyntax("ralt"), "a metrics shortcut on RAlt must be refused")
	AssertEqual("", MS_ToAhkSyntax("ctrl+rctrl"), "a metrics chord ending in RCtrl must be refused")
	AssertEqual("", LLM_Menu_ShortcutToAhk("ctrl+lalt"), "the LLM trigger must keep refusing it")
	_HRMK_NativeCalls := []
	Handle := _HotkeyRegistrarBindOwned("ralt", (*) => 0, "test", _HRMK_Hotkey)
	AssertEqual("", Handle, "the shared registrar must refuse the binding for every client")
	AssertEqual(0, _HRMK_NativeCalls.Length, "a refused modifier key must never reach Hotkey()")
}
Test("hotkey registrar: every client refuses a modifier key (registrar-modifier-key-2026-09-25)",
	_HRMK_EveryClientRefusesAModifierKey)

_HRMK_MetricsPromptExplainsTheRefusal() {
	AssertEqual(Format(t("metrics.shortcut_modifier_key"), "ralt"), MS_ModifierKeyRefusal("ctrl+ralt"),
		"the metrics prompt must tell the user that a modifier key cannot be the shortcut's key")
	AssertEqual("", MS_ModifierKeyRefusal("ctrl+alt+m"), "an ordinary shortcut has no refusal")
	AssertEqual("", MS_ModifierKeyRefusal(""), "clearing the shortcut has no refusal")
	AssertEqual("", MS_ModifierKeyRefusal("crtl+m"), "a malformed chord keeps its own generic path")
}
Test("hotkey registrar: the metrics prompt explains a modifier-key refusal (registrar-modifier-key-2026-09-25)",
	_HRMK_MetricsPromptExplainsTheRefusal)

; The refusal is shown whether or not a tap-hold is configured on the key, so
; no locale may give a tap-hold as its reason.
_HRMK_RefusalBlamesNoTapHold() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	SplitPath(WindowsDir, , &Root)
	Checked := 0
	Loop Files, Root . "\_shared\data\locales\*.json" {
		Raw := FileRead(A_LoopFileFullPath, "UTF-8")
		Assert(RegExMatch(Raw, '"metrics\.shortcut_modifier_key":\s*"((?:[^"\\]|\\.)*)"', &Entry),
			A_LoopFileName . " must carry metrics.shortcut_modifier_key")
		Assert(InStr(Entry[1], "{1}") > 0, A_LoopFileName . " must name the refused key")
		for _, Term in ["tap-hold", "タップホールド", "탭-홀드", "点按-按住"]
			AssertEqual(0, InStr(Entry[1], Term),
				A_LoopFileName . ": the refusal must not blame a tap-hold the key may not have")
		Checked++
	}
	AssertEqual(21, Checked, "every locale must be checked")
}
Test("hotkey registrar: the modifier-key refusal blames no tap-hold (registrar-modifier-key-2026-09-25)",
	_HRMK_RefusalBlamesNoTapHold)
