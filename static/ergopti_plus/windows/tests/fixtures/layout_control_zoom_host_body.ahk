; tests/fixtures/layout_control_zoom_host_body.ahk

; Actual declarations, first-eligible native variant priority and the actual
; host classifier. The host observation and output are passive ports only.
global _SharedDir := A_Args[3], _LRCZ_Sc := A_Args[5], _LRCZ_Mode := A_Args[6]
global _LRCZ_Emits := [], _LRCZ_Exes := Map("word", "WINWORD.EXE", "excel", "EXCEL.EXE", "other", "notepad.exe")
global Features := Map("layout", Map("ergopti_base", true,
	"emulate_number_row", true, "emulate_top_row", true, "emulate_home_row", true, "emulate_bottom_row", true),
	"hotstrings", Map("magic_key", Map("replace", Map("enabled", false))))
global ScriptInformation := Map("MagicKeySourceScan", "SC02E", "MagicKeySourceChosen", false)

OutputHostResolve() {
	global _LRCZ_Mode, _LRCZ_Exes
	if _LRCZ_Mode == "failure"
		throw Error("controlled host observation failure")
	return Map("Valid", _LRCZ_Mode != "invalid", "Exe", _LRCZ_Exes.Get(_LRCZ_Mode, "WINWORD.EXE"))
}
HotPath_Now() => 0
HotPath_LogIfSlow(*) => 0
_EmitReachedScreen() => false
UpdateLastSentCharacter(*) {
	throw Error("the passive shortcut sender must not record text")
}
SendEvent(Text) {
	global _LRCZ_Emits
	_LRCZ_Emits.Push(Map("kind", "event", "text", Text))
}
SendFinalResult(Text, *) {
	global _LRCZ_Emits
	_LRCZ_Emits.Push(Map("kind", "final", "text", Text))
}

_LRCZ_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

; The unchanged AHK2.0.26 Hotkey::CriterionAllowsFiring returns the first
; eligible contextual variant. The same-name plan entries retain the actual
; declaration order; this does not simulate physical hook matching.
_LRCZ_Choose(Name) {
	for Entry in _LRCC_Plan()
		if Entry["name"] == Name && Entry["criterion"].Call(Entry["name"])
			return Entry
	return 0
}

_LRCZ_Emit(Name, Kind, Text, NativeScan := "") {
	global _LRCZ_Emits
	_LRCZ_Emits := []
	Chosen := _LRCZ_Choose(Name)
	WasCritical := Critical("Off")
	try {
		if Chosen is Map
			Chosen["callback"].Call(Chosen["name"])
		else if NativeScan != "" {
			_LRCZ_Require(_LayoutRowPassthroughCriterion(NativeScan, Name), "the genuine native-row owner must remain eligible")
			_LayoutRowPassthrough(NativeScan)
		}
	} finally Critical(WasCritical)
	if Kind == "" {
		_LRCZ_Require(_LRCZ_Emits.Length == 0, "a disabled layout must emit no zoom or paste")
		return
	}
	_LRCZ_Require(_LRCZ_Emits.Length == 1 && _LRCZ_Emits[1]["kind"] == Kind && _LRCZ_Emits[1]["text"] == Text,
		"the actually selected variant must emit the independent host-specific golden")
}

_LRCZ_Check() {
	global _LRCZ_Mode, _LRCZ_Sc, Features
	Plan := _LRCC_Plan()
	_LRCZ_Require(Plan[2]["name"] == "*^SC00C" && Plan[3]["name"] == "*^SC00D"
		&& Plan[4]["name"] == "*^SC00C" && Plan[5]["name"] == "*^SC00D",
		"the genuine ordinary and Microsoft callbacks must keep their same-name source order")
	Office := _LRCZ_Mode == "word" || _LRCZ_Mode == "excel"
	_LRCZ_Require(MicrosoftApps() == Office, "the genuine host classifier must match the independent executable vector")
	Name := "*^" . _LRCZ_Sc
	Zoom := _LRCZ_Sc == "SC00C" ? (Office ? "^{WheelDown}" : "^{NumpadSub}")
		: (Office ? "^{WheelUp}" : "^{NumpadAdd}")
	_LRCZ_Emit(Name, "final", Zoom)
	; Paste is its own cohort and must continue to work inside Office too.
	_LRCZ_Emit("^SC02F", "event", "^v")
	OriginalMode := _LRCZ_Mode
	_LRCZ_Mode := Office ? "other" : "word"
	OtherZoom := _LRCZ_Sc == "SC00C" ? (Office ? "^{NumpadSub}" : "^{WheelDown}")
		: (Office ? "^{NumpadAdd}" : "^{WheelUp}")
	_LRCZ_Emit(Name, "final", OtherZoom)
	_LRCZ_Mode := OriginalMode
	Features["layout"]["emulate_number_row"] := false
	_LRCZ_Emit(Name, "event", "{Blind}{" . _LRCZ_Sc . "}", _LRCZ_Sc)
	Features["layout"]["emulate_number_row"] := true
	_LRCZ_Emit(Name, "final", Zoom)
	Features["layout"]["ergopti_base"] := false
	_LRCZ_Emit(Name, "", "")
	_LRCZ_Emit("^SC02F", "", "")
}

try {
	_LRCZ_Check()
	FileAppend("PASS layout-zoom-host-precedence", "*")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
