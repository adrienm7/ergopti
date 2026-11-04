; tests/fixtures/builtin_number_row_magic_body.ahk

; Genuine XML tables and all competing built-in producers. Only registration
; and output are ports; no native DLL, host key or foreground window is touched.
global _SharedDir := A_Args[3], _StaticDir := A_Args[8], _DriverDir := A_Args[9]
global _LRPN_Scan := A_Args[5], _LRPN_Row := A_Args[6] == "on", _LRPN_Caps := A_Args[7] == "on"
global Features := Map("layout", Map("ergopti_base", true, "ergopti_variant", "ergopti", "emulated_layout", "",
	"ctrl_magic_save", false, "direct_access_digits", "native", "emulate_number_row", _LRPN_Row,
	"emulate_top_row", true, "emulate_home_row", true, "emulate_bottom_row", true),
	"hotstrings", Map("magic_key", Map("replace", Map("enabled", true))))
global ScriptInformation := Map("MagicKeySourceChosen", true, "MagicKeySourceScan", _LRPN_Scan,
	"MagicKeySourceOverridesEmulation", true, "MagicKeySourceChar", "q", "MagicKey", Chr(0x2605))
global CategoryEnabled := Map("Layout", true), LayerEnabled := false, KLE_Model := 0, KLE_Id := ""
global _LRPN_Current := 0, _LRPN_Entries := Map(), _LRPN_Emits := [], _LRPN_Registrations := 0

HotIf(Args*) {
	global _LRPN_Current
	_LRPN_Current := Args.Length ? Args[1] : 0
}
Hotkey(Name, Callback, Options) {
	global _LRPN_Current, _LRPN_Entries, _LRPN_Registrations
	_LRPN_Registrations += 1
	if !_LRPN_Entries.Has(Name)
		_LRPN_Entries[Name] := []
	for Entry in _LRPN_Entries[Name] {
		if Entry["criterion"] == _LRPN_Current {
			Entry["callback"] := Callback, Entry["options"] := Options
			return
		}
	}
	_LRPN_Entries[Name].Push(Map("name", Name, "callback", Callback, "criterion", _LRPN_Current, "options", Options))
}
GetKeyState(Key, *) {
	global _LRPN_Caps
	return Key == "CapsLock" ? _LRPN_Caps : false
}
GetForegroundKeyboardLayout() => 0x7E570409
; The JSON owner ends each string run with the native text adapter's wcscspn
; and skips whitespace and number runs with its wcsspn; both read memory only.
; Replay exactly those calls unit by unit; every other native call, a layout or
; profile probe above all, stays refused.
DllCall(Function, Args*) {
	Including := Function == "msvcrt\wcsspn"
	if !((Including || Function == "msvcrt\wcscspn") && Args.Length == 5 && Args[1] == "Ptr"
			&& Args[3] == "Ptr" && Args[5] == "Cdecl UPtr")
		throw Error("native DLL calls are outside this passive ownership fixture")
	static Members := Map(), MembersOf := 0
	if !(IsObject(MembersOf) && MembersOf == Args[4]) {
		Members := Map(), MembersOf := Args[4], SetIndex := 0
		while Member := NumGet(MembersOf, SetIndex++ * 2, "UShort")
			Members[Member] := true
	}
	Offset := 0
	while Unit := NumGet(Args[2], Offset * 2, "UShort") {
		if Members.Has(Unit) != Including
			break
		Offset++
	}
	return Offset
}
SendInput(*) {
	throw Error("native input is outside this passive ownership fixture")
}
SendEvent(Text) {
	global _LRPN_Emits
	_LRPN_Emits.Push(Map("kind", "event", "text", Text))
}
_RemapEmit(Text, Character, *) {
	global _LRPN_Emits
	_LRPN_Emits.Push(Map("kind", "remap", "text", Text))
}
SendNewResult(Text, *) {
	global _LRPN_Emits
	_LRPN_Emits.Push(Map("kind", "new", "text", Text))
}
_EmitReachedScreen() => true
UpdateLastSentCharacter(*) => 0
ActivateHotstrings(*) => 0
WrapTextIfSelected(*) {
	throw Error("the selected number-row controls do not wrap selections")
}
DeadKey(*) {
	throw Error("the selected number-row controls do not arm a dead key")
}

_LRPN_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_LRPN_LoadTables() {
	global _StaticDir, _SharedDir, ERGOPTI_SPEC, KS_DIGIT_ROW_KEYS, _DigitRowProfiles
	Root := _StaticDir . "\layouts\registry\"
	Index := JsonParse(FSReadStrict(Root . "index.json"))
	Models := Map(), Convention := ""
	for Entry in Index["layouts"] {
		if Entry["id"] != "ergopti" && Entry["id"] != "ergopti_plus"
			continue
		_LRPN_Require(Convention == "" || Convention == Entry["keycode_convention"], "the two real layouts must share keycodes")
		Convention := Entry["keycode_convention"]
		Models[Entry["id"]] := Keylayout_Parse(FSReadStrict(Root . StrReplace(Entry["file"], "/", "\")))
	}
	_LRPN_Require(Models.Count == 2, "both real checked-in layouts must parse")
	Keycodes := JsonParse(FSReadStrict(_SharedDir . "\modules\layouts\mac_keycodes.json"))
	ERGOPTI_SPEC := ErgoptiLayout_BuildSpec(Models["ergopti"], Models["ergopti_plus"],
		KeylayoutEmulation_KeyCodes(Keycodes, Convention),
		ErgoptiLayout_ReadWrapPairs(_SharedDir . "\modules\wrap_symbols\wrap_symbols.json"))
	; A regression must not fall through into a native profile probe either.
	Corpus := JsonParse(FSReadStrict(_SharedDir . "\tests\corpus\layouts\number_row_levels.json"))
	Plain := Map(), Shift := Map()
	_LRPN_Require(Corpus["native"][2]["id"] == "qwerty", "the cached fallback must use the independent US vector")
	for I, Key in KS_DIGIT_ROW_KEYS {
		Plain[Key[2]] := Corpus["native"][2]["plain"][I]
		Shift[Key[2]] := Corpus["native"][2]["shift"][I]
	}
	_DigitRowProfiles := Map(0x7E570409, Map("shifted", false, "symbols", Plain, "shift_symbols", Shift,
		"edges", Map(0x29, Map("plain", Chr(0x60), "shift", "~"),
			0x0C, Map("plain", "-", "shift", "_"), 0x0D, Map("plain", "=", "shift", "+"))))
}

; Independent external oracle: AHK2.0.26 Hotkey::CriterionAllowsFiring
; (source/hotkey.cpp) returns the first eligible contextual variant before
; its global fallback. An unchanged C++ probe validates this priority separately;
; this selector never derives an expected result from the production predicate.
_LRPN_Select(Name) {
	global _LRPN_Entries
	Fallback := 0
	for Entry in _LRPN_Entries.Get(Name, []) {
		if !HasMethod(Entry["criterion"], "Call")
			Fallback := Entry
		else if Entry["criterion"].Call(Entry["name"])
			return Entry
	}
	return Fallback
}

_LRPN_Output(Name, Kind, Text) {
	global _LRPN_Emits
	Entry := _LRPN_Select(Name)
	_LRPN_Require(Entry is Map, "the real cohort must retain an admitted owner of " . Name)
	_LRPN_Emits := []
	Entry["callback"].Call(Entry["name"])
	_LRPN_Require(_LRPN_Emits.Length == 1 && _LRPN_Emits[1]["kind"] == Kind && _LRPN_Emits[1]["text"] == Text,
		"the actually selected callback must emit exactly the independent expected result for " . Name)
	return Entry
}

_LRPN_Check() {
	global _LRPN_Scan, _LRPN_Row, _LRPN_Caps, Features, ScriptInformation, _DriverDir, _LRPN_Current, _LRPN_Registrations
	global _ALTGR_KANA_FIXUP, _ALTGR_LAYOUT_PROBE
	_LRPN_LoadTables()
	_LRPN_Require(NumberRowEffectiveMode() == "native", "independent static ordering owners must be inert in this scenario")
	_LRPN_Require(!KeylayoutEmulation_IsActive(), "the helper must admit magic without requiring a registry emulation")
	RegisterLayoutRowPassthrough(Hotkey, HotIf)
	_LRPCM_RegisterMagic()
	RegisterShiftLayer()
	Before := _LRPN_Registrations
	RegisterBuiltinNumberRow()
	_LRPN_Require(_LRPN_Registrations - Before == 23, "all thirteen Down and ten digit Up callbacks must register")
	RegisterCapsLockLayer()
	_LRPN_Require(_LRPN_Current == 0, "every real producer must reset its registration criterion")
	Golden := JsonParse(FSReadStrict(_DriverDir . "\tests\fixtures\ergopti_emulation_golden.json"))
	MagicKind := _LRPN_Caps ? "new" : "remap"
	MagicText := (_LRPN_Caps ? "" : "{Text}") . ScriptInformation["MagicKey"]
	for Family in ["plain", "altgr", "kana"] {
		_ALTGR_KANA_FIXUP := Family == "kana"
		_ALTGR_LAYOUT_PROBE := Map("hkl", 0x7E570409, "valid", true, "source", "probe",
			"kana", Family == "kana", "altgr_level", Family == "altgr", "rmenu_sc", Family == "kana" ? 0 : 0xE038,
			"altgr_vk", Family == "kana" ? 0xDF : 0xA5)
		_LRPN_Output(_LRPN_Scan, MagicKind, MagicText)
		_LRPN_Require(!(_LRPN_Select(_LRPN_Scan . " Up") is Map), "a chosen full-stroke magic press owns no synthetic digit release")
	}
	; The sibling digit keeps its real paired Down/Up only while that owner wins.
	if !_LRPN_Row
		_LRPN_Output("SC003", "event", "{Blind}{SC003}")
	else if _LRPN_Caps
		_LRPN_Output("SC003", "new", "2")
	else {
		Down := _LRPN_Output("SC003", "event", "{2 Down}")
		Up := _LRPN_Output("SC003 Up", "event", "{2 Up}")
		_LRPN_Require(Down["criterion"] == Up["criterion"], "the ordinary digit must retain one criterion for its matching pair")
	}
	if !_LRPN_Row || _LRPN_Caps
		_LRPN_Require(!(_LRPN_Select("SC003 Up") is Map), "a passed-through or Caps stroke owns no synthetic digit Up")
	if _LRPN_Row
		_LRPN_Output("+" . _LRPN_Scan, "new", Golden["levels"]["shift"][_LRPN_Scan]["text"])
	else
		_LRPN_Output("+" . _LRPN_Scan, "event", "{Blind}{" . _LRPN_Scan . "}")
	Features["layout"]["ergopti_base"] := false
	_LRPN_Output(_LRPN_Scan, MagicKind, MagicText)
	Features["layout"]["ergopti_base"] := true
	Features["hotstrings"]["magic_key"]["replace"]["enabled"] := false
	if !_LRPN_Row
		_LRPN_Output(_LRPN_Scan, "event", "{Blind}{" . _LRPN_Scan . "}")
	else if _LRPN_Caps
		_LRPN_Output(_LRPN_Scan, "new", Golden["levels"]["caps"][_LRPN_Scan]["text"])
	else if _LRPN_Scan == "SC002" {
		_LRPN_Output(_LRPN_Scan, "event", "{1 Down}")
		_LRPN_Output(_LRPN_Scan . " Up", "event", "{1 Up}")
	} else
		_LRPN_Output(_LRPN_Scan, "event", "{Text}" . Map("SC029", "$", "SC00C", "%", "SC00D", "=")[_LRPN_Scan])
}

try {
	_LRPN_Check()
	FileAppend("PASS builtin-number-row-magic-owner", "*")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
