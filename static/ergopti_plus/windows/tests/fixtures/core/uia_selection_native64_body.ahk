; tests/fixtures/core/uia_selection_native64_body.ahk

; The provider terminal reply is explicit fixture input, not real UIA success.
; Native foreground/control and the genuine publisher/getter/validator are used.
; Only TickElapsed64's default current-clock read is observed and rebound; neither
; the producer's CapturedAt nor the consumed flag is assigned by this fixture.
if A_Args.Length != 2 || A_Args[1] != "--allow-owned-uia-native64"
	throw Error("Explicit owned receiver opt-in is required.")
if !(A_Args[2] == "current" || A_Args[2] == "one-era" || A_Args[2] == "two-eras")
	throw Error("A known age vector is required.")
global _UIA_SelectionCache := 0, _UIA_NO_TP_CACHE := Map(), _UIA_WORKER_BACKOFF_CACHE := Map()
global _UIA_NO_TP_TTL_MS := 1000, UIASW_DEADLINE_MS := 1000
global _US64 := {Now: 0, Reads: 0, Diagnostics: 0}
_US64_Clock() {
	global _US64
	_US64.Reads += 1
	return _US64.Now
}
LoggerWarn(*) {
	global _US64
	_US64.Diagnostics += 1
}
LoggerInfo(*) => 0
_US64_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
_US64_Main() {
	global _US64, _UIA_SelectionCache
	ReceiverGui := Gui(, "Ergopti owned UIA age receiver")
	Receiver := ReceiverGui.AddEdit("w320 r3", "selected")
	try {
		ReceiverGui.Show()
		WinActivate("ahk_id " . ReceiverGui.Hwnd)
		_US64_Require(WinWaitActive("ahk_id " . ReceiverGui.Hwnd, , 2), "The owned native receiver must become active.")
		Receiver.Focus()
		PreviousCritical := Critical("On")
		try {
			Context := _UIA_CurrentSelectionContext("owned-fixture.exe")
			_US64_Require(Context is Map && Context["Hwnd"] == ReceiverGui.Hwnd && Context["Control"] == Receiver.Hwnd,
				"Actual foreground and native focused-control identities must belong to this child.")
			Reply := Map("Hwnd", ReceiverGui.Hwnd, "Control", Receiver.Hwnd, "Text", Receiver.Value)
			_UIA_OnSelectionWorkerTerminal("ok", Context, Reply)
			_US64_Require(IsObject(_UIA_SelectionCache) && _UIA_SelectionCache.Text == Receiver.Value,
				"The genuine terminal producer must publish the controlled provider result.")
			Snapshot := _UIA_SelectionCache
			Origin := Snapshot.CapturedAt
			Eras := A_Args[2] == "current" ? 0 : (A_Args[2] == "one-era" ? 1 : 2)
			_US64.Now := Origin + Eras * 0x100000000 + 100
			Actual := GetUIASelection()
			Reads := _US64.Reads
			FileAppend("OBS uia-selection-native64 mode=" . A_Args[2] . " origin=" . Origin
				. " now=" . _US64.Now . " elapsed=" . (_US64.Now - Origin) . " reads=" . Reads
				. " consumed=" . Snapshot.Consumed . " text_units=" . StrLen(Actual) . "`n", "*")
			_US64_Require(_US64.Diagnostics == 0, "No producer diagnostic may stand in for valid publication.")
			_US64_Require(Reads == 1, "The actual consumer must observe exactly its one current-clock port.")
			_US64_Require(Snapshot.CapturedAt == Origin, "The producer timestamp must remain unchanged.")
			_US64_Require(_UIA_CurrentInputEpoch() == Context["InputEpoch"], "No physical-input change may explain the decision.")
			if Eras == 0 {
				_US64_Require(Actual == Receiver.Value && Snapshot.Consumed, "A current selection must remain consumable once.")
				_US64_Require(GetUIASelection() == "", "The actual capability must remain single-use.")
			} else {
				_US64_Require(Actual == "" && !Snapshot.Consumed, "A selection older than a full native DWORD era must be rejected, not consumed.")
			}
		} finally Critical(PreviousCritical)
	} finally ReceiverGui.Destroy()
	FileAppend("PASS uia-selection-native64 " . A_Args[2] . "`n", "*")
}
try {
	_US64_Main()
	ExitApp(0)
} catch as US64EntryFailure {
	FileAppend("FAIL " . US64EntryFailure.Message . " line=" . US64EntryFailure.Line . "`n", "**")
	ExitApp(1)
}
