; tests/fixtures/layout_row_passthrough_body.ahk

; The parent includes the genuine production module and row-policy helpers.
; Only the native registrar and sender are passive: no hook, key, modifier,
; clipboard or foreground window is changed by this child.

global _SharedDir := A_Args[3]
global Features := Map("layout", Map("ergopti_base", true,
	"emulate_number_row", true, "emulate_top_row", false,
	"emulate_home_row", true, "emulate_bottom_row", true),
	"hotstrings", Map("magic_key", Map("replace", Map("enabled", false))))
global ScriptInformation := Map("MagicKeySourceChosen", false, "MagicKeySourceScan", "SC030")
global _LRPS_Bindings := Map(), _LRPS_Current := 0, _LRPS_Emits := []
global _LRPS_Throw := A_Args[2] == "throw"

_LRPS_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_LRPS_HotIf(Args*) {
	global _LRPS_Current
	_LRPS_Current := Args.Length ? Args[1] : 0
}

_LRPS_Register(Name, Callback, Options) {
	global _LRPS_Bindings, _LRPS_Current
	_LRPS_Bindings[Name] := Map("callback", Callback, "criterion", _LRPS_Current, "options", Options)
}

; AHK permits overriding a built-in function in this isolated child only.
; Record the genuine sender's live thread level without injecting any event.
SendEvent(Keys) {
	global _LRPS_Emits, _LRPS_Throw
	_LRPS_Emits.Push(Map("keys", Keys, "level", A_SendLevel))
	if _LRPS_Throw
		throw Error("fixture sender refused")
}

_LRPS_Run() {
	global Features, _LRPS_Bindings, _LRPS_Current, _LRPS_Emits, _LRPS_Throw
	Count := RegisterLayoutRowPassthrough(_LRPS_Register, _LRPS_HotIf)
	_LRPS_Require(Count == 240 && _LRPS_Bindings.Count == 240, "every real row and hotkey prefix must register")
	_LRPS_Require(_LRPS_Current == 0, "registration must restore the native HotIf boundary")
	_LRPS_Require(!(_LRPS_Bindings["*SC01E"]["criterion"]).Call(), "an enabled row must stay emulated")
	Features["layout"]["ergopti_base"] := false
	_LRPS_Require(!(_LRPS_Bindings["*SC010"]["criterion"]).Call(), "disabled emulation must not claim native keys")
	Features["layout"]["ergopti_base"] := true
	CallerLevel := Integer(A_Args[1])
	ObserverMinimum := Integer(A_Args[4])
	for Prefix in ["", "*", "+", "^", "!"] {
		Name := Prefix . "SC010"
		Binding := _LRPS_Bindings[Name]
		_LRPS_Require((Binding["criterion"]).Call(Name), "the disabled row must admit " . Name)
		SendLevel(CallerLevel)
		_LRPS_Emits := []
		Failure := ""
		try (Binding["callback"]).Call(Name)
		catch as Err
			Failure := Err.Message
		_LRPS_Require(Failure == (_LRPS_Throw ? "fixture sender refused" : ""), "sender refusal must propagate exactly")
		_LRPS_Require(A_SendLevel == CallerLevel, "the caller's send level must survive success and refusal")
		_LRPS_Require(_LRPS_Emits.Length == 1, "one admitted press must reach the sender exactly once")
		Emission := _LRPS_Emits[1]
		_LRPS_Require(Emission["keys"] == "{Blind}{SC010}", "physical identity and held modifiers must survive the native route")
		; AHK2.0.26 HotInputLevelAllowsFiring admits only SendLevel > InputLevel.
		; Both I2 and I3 must ignore this already-forwarded physical key.
		InputLevel := Integer(SubStr(Binding["options"], 2))
		_LRPS_Require(Emission["level"] <= InputLevel, "forwarded output must not reactivate " . Name)
		_LRPS_Require(Emission["level"] >= ObserverMinimum, "forwarded output must still reach the real input observers")
	}
}

try {
	_LRPS_Run()
	FileAppend("PASS row-passthrough-level-custody", "*")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
