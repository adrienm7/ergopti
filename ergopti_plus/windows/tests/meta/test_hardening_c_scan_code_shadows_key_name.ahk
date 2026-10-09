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
; the active layout, but the AltGr layer declares every one of them by scan code
; ("SC138 & SCnnn", whatever the emulation state), so a hotkey the hook owns
; that names a character ("~^v", "$^x", "^y" under #HotIf or #InputLevel 2)
; never fires either: the keylogger's "~^v" paste hotkey never did. A plain,
; global "^!+i::" at #InputLevel 0 is a RegisterHotKey hotkey instead, matched
; by the OS on its virtual key once the hook lets the key through, so it stays
; legal. #InputLevel, #HotIf and #UseHook carry across #Include, so each static
; label's context comes from walking the include graph of the driver's root
; scripts in parse order; a literal Hotkey() call counts as a hook hotkey.
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
	for Declaration in _HCSC_ArrayLoopDeclarations(Code) {
		CallCount++
		Found.Push(Declaration)
	}
	return Found
}

; The bounded computed-registration form: a literal key array and a loop
; concatenating a literal modifier prefix with each key. Dynamic expressions
; remain outside this source scan; runtime registration tests judge them.
_HCSC_ArrayLoopDeclarations(Code) {
	Quotes := Chr(34) . "'"
	Arrays := Map()
	Position := 1
	while (At := RegExMatch(Code, "im)^global\s+(\w+)\s*:=\s*\[([^\]]*)\]", &Literal, Position)) {
		Position := At + Literal.Len
		Keys := []
		Valid := true
		for Token in StrSplit(Literal[2], ",") {
			Token := Trim(Token, " `t`n`r")
			if (Token == "")
				continue
			if !RegExMatch(Token, "^([" . Quotes . "])([A-Za-z][A-Za-z0-9_]*)\1$", &Key) {
				Valid := false
				break
			}
			Keys.Push(Key[2])
		}
		if Valid && Keys.Length
			Arrays[Literal[1]] := Keys
	}
	Found := []
	Position := 1
	Pattern := "for\s+(\w+)\s+in\s+(\w+)\s*\{\s*Hotkey(?:\w*\.Call)?\(\s*([" . Quotes . "])([~*$#!^+<>]*)\3\s*\.\s*\1\s*,"
	while (At := RegExMatch(Code, Pattern, &Registration, Position)) {
		Position := At + Registration.Len
		if Arrays.Has(Registration[2])
			for Key in Arrays[Registration[2]]
				Found.Push(Registration[4] . Key)
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

; One static label, anchored on its own line: a key, an optional combination
; partner and " Up", then "::".
global _HCSC_LABEL_LINE := "i)^[ \t]*([~*$#!^+<>]*[A-Za-z][A-Za-z0-9_]*(?:[ \t]*&[ \t]*~?[A-Za-z][A-Za-z0-9_]*)?(?:[ \t]+up)?)[ \t]*::"

; Windows virtual-key ranges (WinUser.h) that name characters: digits, letters
; and the OEM punctuation keys the active layout assigns.
global _HCSC_CHARACTER_VK_RANGES := [[0x30, 0x39], [0x41, 0x5A], [0xBA, 0xC0], [0xDB, 0xDF], [0xE2, 0xE2]]

; "SCnnn" -> registry code of every character key: a key with no fixed name.
_HCSC_CharacterScanCodes() {
	Registry := JsonParse(FileRead(A_ScriptDir . "\..\..\_shared\data\keycodes\physical_keys.json", "UTF-8"))
	Keys := Map()
	for Code, Rec in Registry["keys"] {
		if (Rec["kind"] != "key") || ((Rec["ahk_send"] is String) && (Rec["ahk_send"] != ""))
			continue
		if !(Rec["ahk"] is String) || !RegExMatch(Rec["ahk"], "^SC[0-9A-F]{3}$")
			continue
		Keys[Rec["ahk"]] := Code
	}
	return Keys
}

; Whether a lowercased key names a character: one character, or its VK.
_HCSC_IsCharacterKey(Key) {
	global _HCSC_CHARACTER_VK_RANGES
	if (StrLen(Key) = 1)
		return true
	if !RegExMatch(Key, "^vk([0-9a-f]{2})$", &Vk)
		return false
	Code := Integer("0x" . Vk[1])
	for Range in _HCSC_CHARACTER_VK_RANGES {
		if (Code >= Range[1] && Code <= Range[2])
			return true
	}
	return false
}

_HCSC_NamesCharacter(Declaration) {
	for Key in _HCSC_KeysOf(Declaration) {
		if _HCSC_IsCharacterKey(Key)
			return true
	}
	return false
}

; Collapses "." and ".." segments so one file reached by two relative paths is
; visited once, as AutoHotkey includes it once.
_HCSC_NormalizePath(RawPath) {
	Segments := []
	for Segment in StrSplit(StrReplace(RawPath, "/", "\"), "\") {
		if (Segment = "..") {
			if (Segments.Length > 1)
				Segments.Pop()
		} else if (Segment != "." && Segment != "") {
			Segments.Push(Segment)
		}
	}
	Joined := ""
	for Index, Segment in Segments
		Joined .= (Index = 1 ? "" : "\") . Segment
	return Joined
}

; One #Include argument (after its *i) resolved as AutoHotkey v2 does: relative
; to the including file's directory, or to the last directory an #Include
; named; %A_ScriptDir% is the driver root. Library and other variable paths
; resolve to "".
_HCSC_ResolveInclude(Argument, Dir, File) {
	if (SubStr(Argument, 1, 1) = "<")
		return ""
	SplitPath(A_ScriptDir, , &DriverRoot)
	Expanded := StrReplace(StrReplace(Argument, "%A_ScriptDir%", DriverRoot), "%A_LineFile%", File)
	if InStr(Expanded, "%")
		return ""
	if !RegExMatch(Expanded, "^[A-Za-z]:[\\/]")
		Expanded := Dir . "\" . Expanded
	return _HCSC_NormalizePath(Expanded)
}

; Applies one masked line to the positional directive state. Returns the file
; an #Include names, for the caller to visit in place, or "".
_HCSC_ApplyDirective(Line, State, Cursor) {
	if RegExMatch(Line, "i)^\s*#InputLevel\b\s*(\d*)", &Directive) {
		State["level"] := (Directive[1] = "") ? 0 : Integer(Directive[1])
	} else if RegExMatch(Line, "i)^\s*#UseHook\b\s*(\S*)", &Directive) {
		State["usehook"] := !RegExMatch(Directive[1], "i)^(false|off|0)$")
	} else if RegExMatch(Line, "i)^\s*#HotIf\b(.*)$", &Directive) {
		State["hotif"] := (Trim(Directive[1]) != "")
	} else if RegExMatch(Line, "i)^\s*#Include(?:Again)?\s+(?:\*i\s+)?(.+?)\s*$", &Directive) {
		Target := _HCSC_ResolveInclude(Directive[1], Cursor["dir"], Cursor["file"])
		Attributes := (Target = "") ? "" : FileExist(Target)
		if InStr(Attributes, "D")
			Cursor["dir"] := Target
		else if (Attributes != "")
			return Target
	}
	return ""
}

; Visits one file in parse order, following its #Include directives in place,
; and records every static label with its file and the directive context at
; its line. A label is "owned" when its file is production source and so is
; every file that led to it: the generated personal-shortcuts stub includes
; the user's own file, which lives outside the driver and whose hotkeys are
; theirs (15 of them failed this census on the maintainer's machine).
_HCSC_WalkIncludes(File, State, Seen, Labels, Owned := true) {
	global _HCSC_LABEL_LINE
	if Seen.Has(StrLower(File))
		return
	Seen[StrLower(File)] := true
	Owned := Owned && _DriverIsProductionSource(File)
	Src := FileRead(File, "UTF-8")
	Masked := _DriverMaskNonCode(&Src)
	SplitPath(File, , &Dir)
	Cursor := Map("dir", Dir, "file", File)
	for Line in StrSplit(Masked, "`n", "`r") {
		Target := _HCSC_ApplyDirective(Line, State, Cursor)
		if (Target != "")
			_HCSC_WalkIncludes(Target, State, Seen, Labels, Owned)
		else if RegExMatch(Line, _HCSC_LABEL_LINE, &Label)
			Labels.Push(Map("text", Label[1], "file", File, "owned", Owned, "context", State.Clone()))
	}
}

; Why AutoHotkey's hook, not RegisterHotKey, owns a static label ("" for a
; registered hotkey), from its syntax and its directive context.
_HCSC_HookReasons(Text, Context) {
	Reasons := ""
	RegExMatch(Text, "^[~*$#!^+<>]*", &Prefix)
	for Symbol in ["~", "$", "*", "<", ">"] {
		if InStr(Prefix[0], Symbol)
			Reasons .= ", the " . Symbol . " prefix"
	}
	if RegExMatch(Text, "i)\s+up\s*$")
		Reasons .= ", a key-up hotkey"
	if InStr(Text, "&")
		Reasons .= ", a custom combination"
	if Context["hotif"]
		Reasons .= ", a #HotIf criterion"
	if (Context["level"] != 0)
		Reasons .= ", #InputLevel " . Context["level"]
	if Context["usehook"]
		Reasons .= ", #UseHook"
	return LTrim(Reasons, ", ")
}

; Character-key declarations the hook owns, comma-separated in order: static
; labels with a hook reason, then every literal Hotkey() registration, whose
; HotIf context no scan knows.
_HCSC_CharacterOffenders(Labels, Calls) {
	Offenders := ""
	for Entry in Labels {
		if _HCSC_NamesCharacter(Entry["text"]) && (_HCSC_HookReasons(Entry["text"], Entry["context"]) != "")
			Offenders .= (Offenders = "" ? "" : ", ") . Entry["text"]
	}
	for Text in Calls {
		if _HCSC_NamesCharacter(Text)
			Offenders .= (Offenders = "" ? "" : ", ") . Text
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

_HCSC_ComputedResetNamesAreScanned() {
	Fixture := "SC00E:: return`nSC001:: return`n"
		. 'global ResetKeys := ["BackSpace", "Escape"]' . "`n"
		. 'for Key in ResetKeys {' . "`n"
		. '    HotkeyFn.Call("~" . Key, Reset)' . "`n}" . "`n"
		. 'global Unknown := [SomeFunction()]' . "`n"
		. 'for Key in Unknown {' . "`n"
		. '    Hotkey("~" . Key, Reset)' . "`n}"
	Masked := _DriverMaskNonCode(&Fixture)
	Found := _HCSC_Declarations(Fixture, Masked, &LabelCount, &CallCount)
	AssertEqual(2, LabelCount)
	AssertEqual(2, CallCount, "only the literal array's computed registrations are resolvable")
	AssertEqual("~BackSpace, ~Escape", _HCSC_Offenders(Found, _HCSC_NameTable()),
		"computed reset names retain the same shadowing rule as literal hotkeys")
}
Test("hotkeys: computed dead-key reset names are scanned (keylayout-dead-reset-identity)",
	_HCSC_ComputedResetNamesAreScanned)

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

_HCSC_CharacterScannerFlagsHookOwnedCharacters() {
	global _HCSC_LABEL_LINE
	Fixture := "^!+i:: {`n}`n#InputLevel 2`n^!+j:: return`n#InputLevel 0`n#HotIf Foo()`n^k:: return`n#HotIf`n"
		. "$^m:: return`nTab:: return`nSC02F:: return`n"
		. 'Hotkey("~^v", Fn)' . "`n"
		. 'Hotkey("~^vk56", Fn)' . "`n"
		. 'Hotkey("^vk0D", Fn)' . "`n"
	Masked := _DriverMaskNonCode(&Fixture)
	State := Map("level", 0, "hotif", false, "usehook", false)
	Cursor := Map("dir", A_ScriptDir, "file", A_ScriptFullPath)
	Labels := []
	for Line in StrSplit(Masked, "`n", "`r") {
		_HCSC_ApplyDirective(Line, State, Cursor)
		if RegExMatch(Line, _HCSC_LABEL_LINE, &Label)
			Labels.Push(Map("text", Label[1], "context", State.Clone()))
	}
	Found := _HCSC_Declarations(Fixture, Masked, &LabelCount, &CallCount)
	AssertEqual(LabelCount, Labels.Length, "the line walk must see every static label of the fixture")
	Calls := []
	Loop CallCount
		Calls.Push(Found[LabelCount + A_Index])
	AssertEqual("^!+j, ^k, $^m, ~^v, ~^vk56", _HCSC_CharacterOffenders(Labels, Calls),
		"the scanner must flag every character hotkey the hook owns, and spare a plain global one at #InputLevel 0")
}
Test("hotkeys: the character-key scanner flags exactly the hook-owned shapes (hardening-c-scan-code-precedence)",
	_HCSC_CharacterScannerFlagsHookOwnedCharacters)

_HCSC_NoHookHotkeyNamesACharacter() {
	Src := _DriverSourceConcat()
	Assert(Src != "", "the driver source must be readable for the character-key meta-test")
	Masked := _DriverMaskNonCode(&Src)
	Code := _StripFullLineComments(Src)
	Found := _HCSC_Declarations(Code, Masked, &LabelCount, &CallCount)
	ScanCodes := Map()
	for Declaration in Found {
		for Key in _HCSC_KeysOf(Declaration) {
			if RegExMatch(Key, "^sc([0-9a-f]{3})$", &Sc)
				ScanCodes["SC" . StrUpper(Sc[1])] := true
		}
	}
	; The premise: the AltGr layer registers every key of the emulation's AltGr
	; levels as "SC138 & SCnnn", unconditionally; the golden fixture freezes them.
	Assert(RegExMatch(Code, "m)^RegisterAltGrLayer\(\)\s*$") > 0,
		"the layout must still register the AltGr layer unconditionally")
	StrReplace(Code, 'Hotkey("SC138 & " . SC,', , , &AltGrRegistrations)
	if RegExMatch(Code, "m)^RegisterAltGrLayer\(HotkeyFn := Hotkey, HotIfFn := HotIf, DispatchFn := AltGrShiftDispatch, RealAltGrFn := IsRealAltGrPress\) \{([\s\S]*?)^\}", &NativeProducer)
		&& !RegExMatch(NativeProducer[1], "m)^\s*HotkeyFn\s*:=") {
		RegExReplace(NativeProducer[1], 'm)^\s*HotkeyFn\.Call\("SC138 & " \. SC,', , &NativePortRegistrations)
		AltGrRegistrations += NativePortRegistrations
	}
	Assert(AltGrRegistrations >= 3, "the AltGr layer must still register its keys as SC138 & SCnnn hotkeys")
	Golden := JsonParse(FileRead(A_ScriptDir . "\fixtures\ergopti_emulation_golden.json", "UTF-8"))
	AltGr := Map()
	for Level in ["altgr_rows", "altgr_number_row", "altgr_plus"] {
		for Sc in Golden["levels"][Level]
			AltGr[StrUpper(Sc)] := true
	}
	Characters := _HCSC_CharacterScanCodes()
	Assert(Characters.Count > 40, "the registry must name the character keys, found " . Characters.Count)
	Undeclared := ""
	for Sc, KeyCode in Characters {
		if !AltGr.Has(Sc) && !ScanCodes.Has(Sc)
			Undeclared .= (Undeclared = "" ? "" : ", ") . KeyCode
	}
	AssertEqual("", Undeclared,
		"every character key must stay declared by scan code, or the character rule below must be revisited")

	; Driver labels only, as _DriverSourceConcat reads them: tests, vendor code
	; and generated files are not the driver's own hotkeys.
	SplitPath(A_ScriptDir, , &DriverRoot)
	Seen := Map()
	Walked := []
	Loop Files, DriverRoot . "\*.ahk" {
		State := Map("level", 0, "hotif", false, "usehook", false)
		_HCSC_WalkIncludes(A_LoopFileFullPath, State, Seen, Walked)
	}
	Labels := []
	for Entry in Walked {
		if Entry["owned"]
			Labels.Push(Entry)
	}
	Assert(Seen.Count > 100, "the #Include walk from the driver root scripts must reach the driver, reached " . Seen.Count)
	Leveled := 0
	Criteria := 0
	for Entry in Labels {
		if (Entry["context"]["level"] != 0)
			Leveled++
		if Entry["context"]["hotif"]
			Criteria++
	}
	Assert(Leveled > 20, "the #Include walk must place the layout hotkeys under #InputLevel 2, found " . Leveled)
	Assert(Criteria > 20, "the #Include walk must see the #HotIf criteria of static hotkeys, found " . Criteria)
	AssertEqual(LabelCount, Labels.Length,
		"every driver hotkey must be reachable from a driver root script through #Include")
	Calls := []
	Loop CallCount
		Calls.Push(Found[LabelCount + A_Index])
	AssertEqual("", _HCSC_CharacterOffenders(Labels, Calls),
		"a hotkey the hook owns never fires on a character key, all of which are declared by scan code: "
		. "observe the key on the HookDispatcher, declare it by scan code, or keep it a plain global hotkey at #InputLevel 0")
}
Test("hotkeys: no hook-owned hotkey names a character key (hardening-c-scan-code-precedence)",
	_HCSC_NoHookHotkeyNamesACharacter)

_HCSC_ProductionPathOwnership() {
	for Path, Expected in Map(
		"C:\driver\ui\hotkeys.ahk", true,
		"C:/driver/ui/hotkeys.ahk", true,
		"C:\driver\_generated\personal_shortcuts.ahk", false,
		"C:/driver/_generated/personal_shortcuts.ahk", false,
		"C:/driver/_GENERATED/personal_shortcuts.ahk", false,
		"C:/driver/build/bundle_inventory.ahk", false,
		"C:\driver\build\bundle_inventory.ahk", false,
		"C:/driver/BUILD/bundle_inventory.ahk", false,
		"C:/driver/build_picker.ahk", true,
		"C:/driver/tests/fixture.ahk", false,
		"C:/driver/vendor/fixture.ahk", false,
		"C:/driver/ui/vendor_picker.ahk", true,
		"C:/driver/_generated_extra/owned.ahk", true)
		AssertEqual(Expected, _DriverIsProductionSource(Path), "source ownership: " . Path)
}
Test("hotkeys: source and include censuses share generated-code ownership",
	_HCSC_ProductionPathOwnership)

; Generated personal shortcuts affect directives after their include even
; though their own hotkeys are not part of the production source census.
_HCSC_PersonalIncludePreservesContext() {
	Root := A_Temp . "\ergopti-hcsc-" . A_TickCount . "-" . Random(10000, 99999)
	Driver := Root . "\driver.ahk"
	Personal := Root . "\_generated\personal_shortcuts.ahk"
	; The user's own file, outside the driver, which the generated stub includes.
	UserFile := Root . "\elsewhere\personal_shortcuts.ahk"
	Owned := Root . "\ui\hotkeys.ahk"
	DirCreate(Root . "\_generated")
	DirCreate(Root . "\elsewhere")
	DirCreate(Root . "\ui")
	try {
		FileAppend("#InputLevel 0`n#Include _generated/personal_shortcuts.ahk`n#Include ui/hotkeys.ahk`n",
			Driver, "UTF-8")
		FileAppend('#InputLevel 2`n#HotIf WinActive("fixture")`n^v::return`n#Include *i ' . UserFile
			. '`n#UseHook true`n', Personal, "UTF-8")
		FileAppend("^k::return`n+SC02E::return`n", UserFile, "UTF-8")
		FileAppend("SC02F::return`n", Owned, "UTF-8")
		State := Map("level", 0, "hotif", false, "usehook", false)
		Seen := Map(), Walked := [], Labels := []
		_HCSC_WalkIncludes(Driver, State, Seen, Walked)
		AssertEqual(4, Seen.Count, "the generated include is traversed too, and the user's file it includes")
		for Entry in Walked {
			if Entry["owned"]
				Labels.Push(Entry)
		}
		AssertEqual(1, Labels.Length,
			"personal hotkeys never enter the driver census, wherever the user's own file lives")
		AssertEqual("SC02F", Labels[1]["text"], "the owned label remains visible")
		AssertEqual(2, Labels[1]["context"]["level"], "generated directives still affect later code")
		AssertTrue(Labels[1]["context"]["hotif"], "the generated criterion remains in force")
		AssertTrue(Labels[1]["context"]["usehook"], "the generated hook directive remains in force")
		Source := FileRead(Driver, "UTF-8") . "`n" . FileRead(Owned, "UTF-8")
		Masked := _DriverMaskNonCode(&Source)
		_HCSC_Declarations(Source, Masked, &Count, &Calls)
		AssertEqual(Count, Labels.Length, "both ownership-aware censuses agree with a personal include")
	} finally {
		if DirExist(Root)
			DirDelete(Root, true)
	}
}
Test("hotkeys: a generated personal include preserves context without changing the census",
	_HCSC_PersonalIncludePreservesContext)
