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
	_LRPS_Require(SubStr(Name, 1, 1) == "~", "every native-row variant must admit its original host event")
	_LRPS_Bindings[StrReplace(Name, "~")] := Map("name", Name, "callback", Callback, "criterion", _LRPS_Current, "options", Options)
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
		_LRPS_Require((Binding["criterion"]).Call(Binding["name"]), "the disabled row must admit " . Name)
		SendLevel(CallerLevel)
		_LRPS_Emits := []
		Failure := ""
		try (Binding["callback"]).Call(Binding["name"])
		catch as Err
			Failure := Err.Message
		_LRPS_Require(Failure == "", "a native pass-through must never call even the refusing sender trap")
		_LRPS_Require(A_SendLevel == CallerLevel, "the pass-through callback must preserve its caller's send level")
		_LRPS_Require(_LRPS_Emits.Length == 0, "the original tilde event must not be duplicated by synthetic output")
		_LRPS_Require(Binding["options"] == (Prefix == "!" ? "I3" : "I2"), "the same five identities must retain their exact input levels")
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
