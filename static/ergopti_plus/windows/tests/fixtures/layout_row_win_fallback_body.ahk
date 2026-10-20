; tests/fixtures/layout_row_win_fallback_body.ahk

; Actual built-in registration and Win broker arbitration; every effectful
; output service is passive. In particular, no Win+L chord can lock the host.
global _SharedDir := A_Args[3]
global _LRPW_Row := A_Args[5], _LRPW_Mode := A_Args[6]
global Features := Map("layout", Map("ergopti_base", true,
	"emulate_number_row", true, "emulate_top_row", true,
	"emulate_home_row", true, "emulate_bottom_row", true),
	"hotstrings", Map("magic_key", Map("replace", Map("enabled", false))))
global ScriptInformation := Map("MagicKeySourceScan", "SC039")
global RemappedList := Map(), KeyboardShortcutAssignments := Map(), LayerEnabled := false
global _LRPW_Emits := []

Hotkey(*) => 0
IsCategoryGated(*) => true
SIHO_HasActive() => false
_EmitReachedScreen() => true
_RemapEmit(Keys, Character, *) {
	global _LRPW_Emits
	_LRPW_Emits.Push(Keys)
}
_LockWorkstationEmit(*) {
	throw Error("the fixture must never request a workstation lock")
}
RunKeyboardShortcutAction(Slot) {
	global _LRPW_Emits
	_LRPW_Emits.Push(Slot)
}

_LRPW_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_LRPW_Run() {
	global _LRPW_Row, _LRPW_Mode, Features, ScriptInformation, KeyboardShortcutAssignments, _LRPW_Emits
	Scan := Map("number", "SC002", "top", "SC010", "home", "SC01E", "bottom", "SC02C")[_LRPW_Row]
	Features["layout"]["emulate_" . _LRPW_Row . "_row"] := _LRPW_Mode == "on"
	if SubStr(_LRPW_Mode, 1, 6) == "magic-" {
		Features["hotstrings"]["magic_key"]["replace"]["enabled"] := true
		ScriptInformation["MagicKeySourceScan"] := _LRPW_Mode == "magic-source" ? Scan : "SC039"
	}
	; This is the production caller: the broker must receive its live admission,
	; rather than a test registering the expected predicate on its behalf.
	RemapKey(Scan, "z")
	RemapKey(Scan, "y")
	State := MagicEditorState()
	_LRPW_Require(State["layouts"][Scan].Length == 1, "a later remap must replace its original broker context")
	Slot := "win_" . StrLower(Scan)
	if _LRPW_Mode == "ordinary" {
		KeyboardShortcutAssignments[Slot] := "copy"
		_LRPW_Require(MagicEditorRecordOrdinaryPhysical(Slot, "copy"), "the explicit physical assignment must join")
	}
	if _LRPW_Mode == "legacy"
		MagicEditorRecordLegacy(Scan, (*) => _LRPW_Emits.Push("legacy"))
	State["initialized"] := true
	ExpectedKind := _LRPW_Mode == "ordinary" ? "ordinary" : _LRPW_Mode == "legacy" ? "legacy"
		: (_LRPW_Mode == "on" || _LRPW_Mode == "magic-source") ? "layout" : ""
	Winner := _MagicEditorBrokerWinner(Scan)
	_LRPW_Require((Winner is Map ? Winner["kind"] : "") == ExpectedKind,
		"row and magic policy must select only the admitted Win owner")
	_LRPW_Require(_MagicEditorBrokerCriterion(Scan, 0, 0) == (ExpectedKind != ""),
		"native consumption must agree with the actual winner")
	_MagicEditorBrokerDispatch(Scan, 0, 0)
	_LRPW_Require(_LRPW_Emits.Length == (ExpectedKind == "" ? 0 : 1), "dispatch must emit only once for an admitted owner")
	if ExpectedKind != ""
		_LRPW_Require(_LRPW_Emits[1] == (ExpectedKind == "ordinary" ? Slot : ExpectedKind == "legacy" ? "legacy" : "#y"),
			"the exact independent owner or mapped Win chord must survive")
	if _LRPW_Mode == "on" {
		Features["layout"]["emulate_" . _LRPW_Row . "_row"] := false
		_LRPW_Require(!(_MagicEditorBrokerWinner(Scan) is Map), "disabling the row must revoke the registered fallback immediately")
		Features["layout"]["emulate_" . _LRPW_Row . "_row"] := true
		_LRPW_Require(_MagicEditorBrokerWinner(Scan) is Map, "reenabling the row must restore its existing fallback")
	}
}

try {
	_LRPW_Run()
	FileAppend("PASS row-win-fallback", "*")
	ExitApp(0)
} catch as Err {
	FileAppend(Err.Message . "`n" . Err.Stack, "**")
	ExitApp(1)
}
