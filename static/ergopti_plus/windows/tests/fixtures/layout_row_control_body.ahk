; tests/fixtures/layout_row_control_body.ahk

; The five actual static declarations' criteria and callbacks run without
; registering host hotkeys or emitting native keyboard/mouse/clipboard input.
global _SharedDir := A_Args[3], _LRCC_Index := Integer(A_Args[5]), _LRCC_Row := A_Args[6] == "on"
global _LRCC_Microsoft := false, _LRCC_Emits := []
global Features := Map("layout", Map("ergopti_base", true,
	"emulate_number_row", true, "emulate_top_row", true, "emulate_home_row", true, "emulate_bottom_row", true),
	"hotstrings", Map("magic_key", Map("replace", Map("enabled", false))))
global ScriptInformation := Map("MagicKeySourceScan", "SC02E", "MagicKeySourceChosen", false)

MicrosoftApps() => _LRCC_Microsoft
HotPath_Now() => 0
HotPath_LogIfSlow(*) => 0
_EmitReachedScreen() => false
UpdateLastSentCharacter(*) {
	throw Error("the passive shortcut sender must not record text")
}
SendEvent(Text) {
	global _LRCC_Emits
	_LRCC_Emits.Push(Map("kind", "event", "text", Text))
}
SendFinalResult(Text, *) {
	global _LRCC_Emits
	_LRCC_Emits.Push(Map("kind", "final", "text", Text))
}

_LRCC_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_LRCC_Exercise(Entry, Sc, Expected, UseNative) {
	global _LRCC_Emits
	_LRCC_Emits := []
	WasCritical := Critical("Off")
	try {
		if Entry["criterion"].Call(Entry["name"])
			Entry["callback"].Call(Entry["name"])
		else if UseNative {
			_LRCC_Require(_LayoutRowPassthroughCriterion(Sc, Entry["name"]),
				"the genuine row producer must admit the physical key")
			_LayoutRowPassthrough(Sc)
		}
	} finally Critical(WasCritical)
	if Expected == "" {
		_LRCC_Require(_LRCC_Emits.Length == 0, "an ineligible control context must emit nothing")
		return
	}
	_LRCC_Require(_LRCC_Emits.Length == 1 && _LRCC_Emits[1]["kind"] == Expected[1]
		&& _LRCC_Emits[1]["text"] == Expected[2],
		"the actual context/callback must preserve the independent shortcut or physical-key result")
}

_LRCC_Check() {
	global _LRCC_Index, _LRCC_Row, _LRCC_Microsoft, Features
	Plan := _LRCC_Plan()
	Names := ["^SC02F", "*^SC00C", "*^SC00D", "*^SC00C", "*^SC00D"]
	Outputs := ["^v", "^{NumpadSub}", "^{NumpadAdd}", "^{WheelDown}", "^{WheelUp}"]
	Entry := Plan[_LRCC_Index]
	_LRCC_Require(Entry["name"] == Names[_LRCC_Index], "the real declaration must retain its modifier/scancode identity")
	Sc := _LRCC_Index == 1 ? "SC02F" : (Mod(_LRCC_Index, 2) == 0 ? "SC00C" : "SC00D")
	Row := _LRCC_Index == 1 ? "bottom_row" : "number_row"
	_LRCC_Require(LayoutRowOf(Sc) == Row, "the independent physical-row vector must match the genuine registry")
	for Other in ["number_row", "top_row", "home_row", "bottom_row"]
		Features["layout"]["emulate_" . Other] := Other == Row ? _LRCC_Row : false
	for Microsoft in [false, true] {
		_LRCC_Microsoft := Microsoft
		Loop 2 {
			Enabled := A_Index == 1 ? _LRCC_Row : !_LRCC_Row
			Features["layout"]["emulate_" . Row] := Enabled
			Expected := !Enabled ? ["event", "{Blind}{" . Sc . "}"]
				: (_LRCC_Index <= 3 || Microsoft ? [_LRCC_Index == 1 ? "event" : "final", Outputs[_LRCC_Index]] : "")
			; For the wildcard zoom declarations the physical stroke includes
			; Shift+Ctrl, where the less-specific row wildcard cannot win first.
			; We test each real context's admission, not a second hook resolver.
			_LRCC_Exercise(Entry, Sc, Expected, !Enabled)
		}
	}
	Features["layout"]["ergopti_base"] := false
	_LRCC_Exercise(Entry, Sc, "", false)
}

try {
	_LRCC_Check()
	FileAppend("PASS layout-row-control-admission", "*")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
