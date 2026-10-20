; tests/fixtures/layout_row_chosen_magic_body.ahk

; Both real producers and the real Win broker retain their callbacks. Registration
; and output are passive, so even an incorrectly admitted owner cannot touch the host.
global _SharedDir := A_Args[3]
global Features := Map("layout", Map("ergopti_base", true, "ctrl_magic_save", false,
	"emulate_number_row", true, "emulate_top_row", true, "emulate_home_row", true, "emulate_bottom_row", true),
	"hotstrings", Map("magic_key", Map("replace", Map("enabled", true))))
global ScriptInformation := Map("MagicKeySourceChosen", true, "MagicKeySourceChar", "q", "MagicKey", Chr(0x2605))
global RemappedList := Map(), KeyboardShortcutAssignments := Map(), LayerEnabled := false
global _LRPCM_Current := 0, _LRPCM_Entries := Map(), _LRPCM_Emits := []

HotIf(Args*) {
	global _LRPCM_Current
	_LRPCM_Current := Args.Length ? Args[1] : 0
}
Hotkey(Name, Callback, Options) {
	global _LRPCM_Current, _LRPCM_Entries
	if !_LRPCM_Entries.Has(Name)
		_LRPCM_Entries[Name] := []
	_LRPCM_Entries[Name].Push(Map("name", Name, "callback", Callback, "criterion", _LRPCM_Current, "options", Options))
}
IsCategoryGated(*) => true
SIHO_HasActive() => false
_EmitReachedScreen() => true
SendEvent(Keys) {
	global _LRPCM_Emits
	_LRPCM_Emits.Push(Map("kind", "physical", "keys", Keys))
}
_RemapEmit(Keys, Character, *) {
	global _LRPCM_Emits
	_LRPCM_Emits.Push(Map("kind", "remap", "keys", Keys))
}
_LockWorkstationEmit(*) {
	throw Error("the passive fixture must never request a workstation lock")
}
_LRPCM_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_LRPCM_Run() {
	global Features, ScriptInformation, _LRPCM_Entries, _LRPCM_Current, _LRPCM_Emits
	Row := A_Args[5]
	Scan := Map("number", "SC002", "top", "SC010", "home", "SC01E", "bottom", "SC02C")[Row]
	Features["layout"]["emulate_" . Row . "_row"] := false
	ScriptInformation["MagicKeySourceScan"] := Scan
	_LRPCM_Require(RegisterLayoutRowPassthrough(Hotkey, HotIf) == 240, "all original row variants must be captured")
	_LRPCM_Require(_LRPCM_Current == 0, "row registration must release its criterion")
	RemapKey(Scan, "z")
	_LRPCM_RegisterMagic()
	_LRPCM_Require(_LRPCM_Entries[Scan].Length == 2, "the actual chosen producer must register exactly one plain magic variant")
	_LRPCM_Require(_LRPCM_Entries[Scan][2]["criterion"] == 0, "the genuine plain magic owner must remain unconditional")
	for Prefix in ["", "*", "+", "^", "!"] {
		Entry := _LRPCM_Entries[Prefix . Scan][1]
		; Pass the actual name captured from the real registrar, as native HotIf does.
		_LRPCM_Require(Entry["criterion"].Call(Entry["name"]) == (Prefix != ""),
			"only the chosen key's plain variant may bypass its native row")
		if Prefix != "" {
			_LRPCM_Emits := []
			Entry["callback"].Call(Entry["name"])
			_LRPCM_Require(_LRPCM_Emits.Length == 1 && _LRPCM_Emits[1]["kind"] == "physical"
				&& _LRPCM_Emits[1]["keys"] == "{Blind}{" . Scan . "}", "modified variants must retain the physical key")
		}
	}
	_LRPCM_Emits := []
	Magic := _LRPCM_Entries[Scan][2]
	Magic["callback"].Call(Magic["name"])
	_LRPCM_Require(_LRPCM_Emits.Length == 1 && _LRPCM_Emits[1]["keys"] == "{Text}" . ScriptInformation["MagicKey"],
		"the real plain producer callback must retain the magic text")
	State := MagicEditorState()
	State["initialized"] := true
	_LRPCM_Require(!(_MagicEditorBrokerWinner(Scan) is Map), "the chosen plain key must not borrow a Win layout fallback on its native row")
	Features["layout"]["emulate_" . Row . "_row"] := true
	_LRPCM_Require(_MagicEditorBrokerWinner(Scan) is Map, "an emulated row must retain the chosen key's ordinary Win mapping")
	for Prefix in ["", "*", "+", "^", "!"] {
		Entry := _LRPCM_Entries[Prefix . Scan][1]
		_LRPCM_Require(!Entry["criterion"].Call(Entry["name"]), "an emulated row needs no native pass-through")
	}
	Features["layout"]["emulate_" . Row . "_row"] := false
	ScriptInformation["MagicKeySourceChosen"] := false
	for Prefix in ["", "*", "+", "^", "!"] {
		Entry := _LRPCM_Entries[Prefix . Scan][1]
		_LRPCM_Require(!Entry["criterion"].Call(Entry["name"]), "the layout's own magic source must retain its established all-level exception")
	}
	_LRPCM_Require(_MagicEditorBrokerWinner(Scan) is Map, "a layout-declared source must retain its Win fallback")
}

try {
	_LRPCM_Run()
	FileAppend("PASS layout-row-chosen-magic", "*")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
