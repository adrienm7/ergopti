; static/drivers/autohotkey/tests/test_tap_hold_loader.ahk

; ==============================================================================
; MODULE: Tap-Hold Loader Tests
; DESCRIPTION:
; Unit-tests for LoadTapHoldToml and the five convenience accessors:
; TapHoldIsConfigured, TapHoldTapAction, TapHoldDuration, TapHoldHoldModifier,
; TapHoldHoldLayer. Exercises the TOML parsing, value coercion, and default
; fallback behaviour without touching the live file system at runtime.
; ==============================================================================





; ======================================
; ==================================
; ======= 1/ LoadTapHoldToml =======
; ==================================
; ======================================

_TH_TmpPath() => A_ScriptDir . "\test_tap_hold_tmp.toml"

_TH_Write(Content) {
	Path := _TH_TmpPath()
	if FileExist(Path) {
		FileDelete(Path)
	}
	FileAppend(Content, Path, "UTF-8")
	return Path
}

_TH_Clean() {
	if FileExist(_TH_TmpPath()) {
		FileDelete(_TH_TmpPath())
	}
}

Test("LoadTapHoldToml: missing file returns empty scaffold", () => {
	TH := LoadTapHoldToml(A_ScriptDir . "\does_not_exist_tap_hold.toml")
	AssertEqual("Map", Type(TH))
	AssertTrue(TH.Has("keys"))
	AssertTrue(TH.Has("layers"))
	AssertEqual(0, TH["keys"].Count)
	AssertEqual(0, TH["layers"].Count)
})

Test("LoadTapHoldToml: parses a single key entry", () => {
	Path := _TH_Write(
		"[tap_hold.keys.caps_lock]`r`n"
		. "tap_action = ""enter""`r`n"
		. "time_activation_seconds = 0.35`r`n"
	)
	TH := LoadTapHoldToml(Path)
	_TH_Clean()
	AssertTrue(TH["keys"].Has("caps_lock"))
	AssertEqual("enter", TH["keys"]["caps_lock"]["tap_action"])
	AssertEqual(0.35, TH["keys"]["caps_lock"]["time_activation_seconds"])
})

Test("LoadTapHoldToml: parses hold_modifier", () => {
	Path := _TH_Write(
		"[tap_hold.keys.left_ctrl]`r`n"
		. "hold_modifier = ""ctrl""`r`n"
	)
	TH := LoadTapHoldToml(Path)
	_TH_Clean()
	AssertEqual("ctrl", TH["keys"]["left_ctrl"]["hold_modifier"])
})

Test("LoadTapHoldToml: parses hold_layer", () => {
	Path := _TH_Write(
		"[tap_hold.keys.space]`r`n"
		. "hold_layer = ""nav""`r`n"
	)
	TH := LoadTapHoldToml(Path)
	_TH_Clean()
	AssertEqual("nav", TH["keys"]["space"]["hold_layer"])
})

Test("LoadTapHoldToml: parses multiple keys independently", () => {
	Path := _TH_Write(
		"[tap_hold.keys.caps_lock]`r`n"
		. "tap_action = ""backspace""`r`n"
		. "[tap_hold.keys.right_ctrl]`r`n"
		. "tap_action = ""tab""`r`n"
	)
	TH := LoadTapHoldToml(Path)
	_TH_Clean()
	AssertEqual(2, TH["keys"].Count)
	AssertEqual("backspace", TH["keys"]["caps_lock"]["tap_action"])
	AssertEqual("tab",       TH["keys"]["right_ctrl"]["tap_action"])
})

Test("LoadTapHoldToml: parses layer mappings block", () => {
	Path := _TH_Write(
		"[tap_hold.layers.nav.mappings]`r`n"
		. "h = ""arrow_left""`r`n"
		. "j = ""arrow_down""`r`n"
	)
	TH := LoadTapHoldToml(Path)
	_TH_Clean()
	AssertTrue(TH["layers"].Has("nav"))
	AssertEqual("arrow_left", TH["layers"]["nav"]["mappings"]["h"])
	AssertEqual("arrow_down", TH["layers"]["nav"]["mappings"]["j"])
})

Test("LoadTapHoldToml: ignores unrecognised section headers", () => {
	Path := _TH_Write(
		"[some_other_section]`r`n"
		. "foo = ""bar""`r`n"
		. "[tap_hold.keys.lalt]`r`n"
		. "tap_action = ""one_shot_shift""`r`n"
	)
	TH := LoadTapHoldToml(Path)
	_TH_Clean()
	AssertEqual(1, TH["keys"].Count)
	AssertFalse(TH["keys"].Has("some_other_section"))
})

Test("LoadTapHoldToml: ignores blank lines and comments", () => {
	Path := _TH_Write(
		"; This is a comment`r`n"
		. "`r`n"
		. "[tap_hold.keys.tab]`r`n"
		. "; another comment`r`n"
		. "tap_action = ""alt_tab_monitor""`r`n"
	)
	TH := LoadTapHoldToml(Path)
	_TH_Clean()
	AssertEqual("alt_tab_monitor", TH["keys"]["tab"]["tap_action"])
})





; ==========================================
; ======================================
; ======= 2/ TapHoldIsConfigured =======
; ======================================
; ==========================================

Test("TapHoldIsConfigured: false when keys map is empty", () => {
	TH := Map("keys", Map(), "layers", Map())
	AssertFalse(TapHoldIsConfigured(TH, "caps_lock"))
})

Test("TapHoldIsConfigured: true when tap_action present", () => {
	TH := Map("keys", Map("caps_lock", Map("tap_action", "enter")), "layers", Map())
	AssertTrue(TapHoldIsConfigured(TH, "caps_lock"))
})

Test("TapHoldIsConfigured: true when hold_modifier present", () => {
	TH := Map("keys", Map("lshift", Map("hold_modifier", "shift")), "layers", Map())
	AssertTrue(TapHoldIsConfigured(TH, "lshift"))
})

Test("TapHoldIsConfigured: true when hold_layer present", () => {
	TH := Map("keys", Map("space", Map("hold_layer", "nav")), "layers", Map())
	AssertTrue(TapHoldIsConfigured(TH, "space"))
})

Test("TapHoldIsConfigured: false when entry exists but has none of the three keys", () => {
	TH := Map("keys", Map("lalt", Map("time_activation_seconds", 0.2)), "layers", Map())
	AssertFalse(TapHoldIsConfigured(TH, "lalt"))
})





; ========================================
; ===================================
; ======= 3/ TapHoldTapAction =======
; ===================================
; ========================================

Test("TapHoldTapAction: returns empty string for unknown key", () => {
	TH := Map("keys", Map(), "layers", Map())
	AssertEqual("", TapHoldTapAction(TH, "caps_lock"))
})

Test("TapHoldTapAction: returns configured value", () => {
	TH := Map("keys", Map("caps_lock", Map("tap_action", "backspace")), "layers", Map())
	AssertEqual("backspace", TapHoldTapAction(TH, "caps_lock"))
})

Test("TapHoldTapAction: returns empty string when tap_action key absent", () => {
	TH := Map("keys", Map("lalt", Map("hold_layer", "nav")), "layers", Map())
	AssertEqual("", TapHoldTapAction(TH, "lalt"))
})





; ======================================
; ==================================
; ======= 4/ TapHoldDuration =======
; ==================================
; ======================================

Test("TapHoldDuration: returns 0.2 default for unknown key", () => {
	TH := Map("keys", Map(), "layers", Map())
	AssertEqual(0.2, TapHoldDuration(TH, "caps_lock"))
})

Test("TapHoldDuration: returns 0.2 default when time_activation_seconds absent", () => {
	TH := Map("keys", Map("lalt", Map("tap_action", "backspace")), "layers", Map())
	AssertEqual(0.2, TapHoldDuration(TH, "lalt"))
})

Test("TapHoldDuration: returns configured value", () => {
	TH := Map("keys", Map("caps_lock", Map("time_activation_seconds", 0.35)), "layers", Map())
	AssertEqual(0.35, TapHoldDuration(TH, "caps_lock"))
})





; ==========================================
; ======================================
; ======= 5/ TapHoldHoldModifier =======
; ======================================
; ==========================================

Test("TapHoldHoldModifier: returns empty string for unknown key", () => {
	TH := Map("keys", Map(), "layers", Map())
	AssertEqual("", TapHoldHoldModifier(TH, "lctrl"))
})

Test("TapHoldHoldModifier: returns configured value", () => {
	TH := Map("keys", Map("lctrl", Map("hold_modifier", "ctrl")), "layers", Map())
	AssertEqual("ctrl", TapHoldHoldModifier(TH, "lctrl"))
})

Test("TapHoldHoldModifier: returns empty string when hold_modifier absent", () => {
	TH := Map("keys", Map("lctrl", Map("tap_action", "tab")), "layers", Map())
	AssertEqual("", TapHoldHoldModifier(TH, "lctrl"))
})





; ========================================
; ===================================
; ======= 6/ TapHoldHoldLayer =======
; ===================================
; ========================================

Test("TapHoldHoldLayer: returns empty string for unknown key", () => {
	TH := Map("keys", Map(), "layers", Map())
	AssertEqual("", TapHoldHoldLayer(TH, "space"))
})

Test("TapHoldHoldLayer: returns configured value", () => {
	TH := Map("keys", Map("space", Map("hold_layer", "nav")), "layers", Map())
	AssertEqual("nav", TapHoldHoldLayer(TH, "space"))
})

Test("TapHoldHoldLayer: returns empty string when hold_layer absent", () => {
	TH := Map("keys", Map("lalt", Map("tap_action", "backspace")), "layers", Map())
	AssertEqual("", TapHoldHoldLayer(TH, "lalt"))
})
