; tests/meta/test_hardening_c_scan_code_shadows_key_name.ahk

; ==============================================================================
; MODULE: No name or VK hotkey on a key declared by scan code
; DESCRIPTION:
; Once any hotkey names a physical key by its scan code ("SC00F::",
; "*$SC00F::", "SC01D & SC138::"), AutoHotkey's hook resolves that key through
; its scan code only: ChangeHookState sets sc_takes_precedence and
; LowLevelCommon looks up the scan-code record alone, letting the key through
; when none of its variants is eligible. A hotkey naming the same key by its
; name or virtual key ("Tab::", "^Tab", "vk09", "Tab Up") never fires.
; The AI prediction's "Tab::" accept was dead from the day remap/tab.ahk
; declared SC00F; the neutral defaults (tap-holds off) exposed it and Tab went
; to the application (llm-tab-accepts-visible-prediction). This test bans the
; whole class for every layout-independent key the physical-key registry
; names (_shared/data/keycodes/physical_keys.json: ahk_send -> ahk), static
; labels and literal Hotkey() registrations alike, and proves its scanner on a
; fixture (hardening-c-scan-code-precedence). Character keys are named through
; the active layout, which no source scan knows, so they stay out of scope.
; tools/test/test-hardening-c-ahk-scan-code-precedence.cjs runs the same scan
; on every OS, before the Windows lane.
; ==============================================================================

#Requires AutoHotkey v2.0

; AutoHotkey spellings of the registry's ahk_send names, lowercased.
global _HCSC_ALIASES := Map("esc", "escape", "bs", "backspace", "del", "delete",
	"ins", "insert", "return", "enter", "lcontrol", "lctrl", "rcontrol", "rctrl")

; Fixed Windows virtual-key codes (WinUser.h) of the layout-independent keys.
global _HCSC_VK_NAMES := Map("08", "backspace", "09", "tab", "0d", "enter",
	"14", "capslock", "1b", "escape", "20", "space", "21", "pgup", "22", "pgdn",
	"23", "end", "24", "home", "25", "left", "26", "up", "27", "right",
	"28", "down", "2d", "insert", "2e", "delete", "5b", "lwin", "5c", "rwin",
	"5d", "appskey", "a0", "lshift", "a1", "rshift", "a2", "lctrl", "a3", "rctrl",
	"a4", "lalt", "a5", "ralt")

; Lowercased key name or vkNN -> "SCnnn", read from the physical-key registry.
_HCSC_NameTable() {
	global _HCSC_ALIASES, _HCSC_VK_NAMES
	static Table := 0
	if IsObject(Table)
		return Table
	Registry := JsonParse(FileRead(A_ScriptDir . "\..\..\_shared\data\keycodes\physical_keys.json", "UTF-8"))
	Names := Map()
	for Code, Rec in Registry["keys"] {
		if (Rec["kind"] != "key") || !(Rec["ahk_send"] is String) || (Rec["ahk_send"] = "")
			continue
		if !RegExMatch(Rec["ahk"], "^SC[0-9A-F]{3}$")
			continue
		Names[StrLower(Rec["ahk_send"])] := Rec["ahk"]
	}
	for Alias, Name in _HCSC_ALIASES
		if Names.Has(Name)
			Names[Alias] := Names[Name]
	for Vk, Name in _HCSC_VK_NAMES {
		if !Names.Has(Name)
			throw Error("the VK table names " . Name . ", which the physical-key registry lacks")
		Names["vk" . Vk] := Names[Name]
	}
	Table := Names
	return Table
}

; The keys one declaration hooks, lowercased, without prefix symbols or " Up":
; both keys of a custom combination.
_HCSC_KeysOf(Declaration) {
	Keys := []
	for Part in StrSplit(Declaration, "&") {
		Key := RegExReplace(Trim(Part), "i)\s+up$")
		Key := LTrim(Key, "~*$#!^+<>")
		Keys.Push(StrLower(Trim(Key)))
	}
	return Keys
}

; Every hotkey declaration: static labels read on Masked (strings and comments
; blanked) and literal Hotkey() registrations read on Code (strings kept).
_HCSC_Declarations(Code, Masked, &LabelCount, &CallCount) {
	Found := []
	LabelCount := 0
	CallCount := 0
	Position := 1
	while (At := RegExMatch(Masked, "im)^[ \t]*([~*$#!^+<>]*[A-Za-z][A-Za-z0-9_]*(?:[ \t]*&[ \t]*~?[A-Za-z][A-Za-z0-9_]*)?(?:[ \t]+up)?)[ \t]*::", &Label, Position)) {
		Position := At + Label.Len
		LabelCount++
		Found.Push(Label[1])
	}
	Position := 1
	Quotes := Chr(34) . "'"
	while (At := RegExMatch(Code, "Hotkey\(\s*(?:[A-Za-z_]\w*\(\s*)?([" . Quotes . "])([^" . Quotes . "]*)\1(?=\s*[,)])", &Call, Position)) {
		Position := At + Call.Len
		CallCount++
		Found.Push(Call[2])
	}
	return Found
}

; Declarations naming, by name or VK, a key another declaration names by scan
; code, comma-separated in declaration order ("" when none).
_HCSC_Offenders(Declarations, Names) {
	ScanCodes := Map()
	for Declaration in Declarations {
		for Key in _HCSC_KeysOf(Declaration) {
			if RegExMatch(Key, "^sc([0-9a-f]{3})$", &Sc)
				ScanCodes["SC" . StrUpper(Sc[1])] := true
		}
	}
	Offenders := ""
	for Declaration in Declarations {
		for Key in _HCSC_KeysOf(Declaration) {
			if Names.Has(Key) && ScanCodes.Has(Names[Key])
				Offenders .= (Offenders = "" ? "" : ", ") . Declaration
		}
	}
	return Offenders
}

_HCSC_ScannerFindsTheShadowedShape() {
	Fixture := "#HotIf LLM_Tooltip_GetText() != 0`nTab:: {`n}`n#HotIf`nSC00F:: {`n}`n*$SC01C:: return`n"
		. 'Hotkey("~*vk0D", Fn)' . "`n"
		. 'Hotkey("~*Space", Fn)' . "`n"
		. 'Hotkey("SC138 & Esc", Fn)' . "`n"
		. 'Hotkey("SC001", Fn)' . "`n"
	Masked := _DriverMaskNonCode(&Fixture)
	Found := _HCSC_Declarations(Fixture, Masked, &LabelCount, &CallCount)
	AssertEqual(3, LabelCount, "the fixture declares three static labels")
	AssertEqual(4, CallCount, "the fixture registers four literal Hotkey() names")
	AssertEqual("Tab, ~*vk0D, SC138 & Esc", _HCSC_Offenders(Found, _HCSC_NameTable()),
		"the scanner must flag every name or VK use of a key declared by scan code, and nothing else")
}
Test("hotkeys: the scan-code precedence scanner flags exactly the shadowed shapes (hardening-c-scan-code-precedence)",
	_HCSC_ScannerFindsTheShadowedShape)

_HCSC_NoNameHotkeyOnAScanCodeKey() {
	Src := _DriverSourceConcat()
	Assert(Src != "", "the driver source must be readable for the scan-code precedence meta-test")
	Masked := _DriverMaskNonCode(&Src)
	Code := _StripFullLineComments(Src)
	Found := _HCSC_Declarations(Code, Masked, &LabelCount, &CallCount)
	Assert(LabelCount > 100, "the scan must see the driver's static hotkeys, found " . LabelCount)
	Assert(CallCount > 20, "the scan must see the driver's Hotkey() registrations, found " . CallCount)
	Names := _HCSC_NameTable()
	Assert(Names.Count > 40, "the registry must name the layout-independent keys, found " . Names.Count)
	SawTab := false
	for Declaration in Found {
		for Key in _HCSC_KeysOf(Declaration) {
			if (Key = "sc00f")
				SawTab := true
		}
	}
	Assert(SawTab, "the Tab key must still be declared by its scan code (platform/remap/tab.ahk)")
	AssertEqual("", _HCSC_Offenders(Found, Names),
		"a key declared by scan code is looked up by scan code only: name it by that scan code everywhere and let variant order decide precedence")
}
Test("hotkeys: no name or VK hotkey targets a key declared by scan code (hardening-c-scan-code-precedence)",
	_HCSC_NoNameHotkeyOnAScanCodeKey)
