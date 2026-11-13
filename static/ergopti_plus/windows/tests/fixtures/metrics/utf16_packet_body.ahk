; tests/fixtures/metrics/utf16_packet_body.ahk
; Actual owned Edit/InputHook delivery followed by the real JSON/UTF-8 boundary.
#Requires AutoHotkey v2.0

_KSP_Hex(Text) {
	Result := ""
	loop StrLen(Text)
		Result .= Format("{:04X}", NumGet(StrPtr(Text), (A_Index - 1) * 2, "UShort"))
	return Result
}

KL_AppCat_Get(*) => "owned-test-category"

; Explicit classifier cutpoints; these are not spontaneous native race claims.
_KSP_Filter() {
	global _KID, _KSP
	if _KID.Mode == "packet-gap-private" && _KID.CharCalls == 2 {
		_KSP.Cuts += 1
		return true
	}
	if _KID.Mode == "packet-gap-inflight" && _KID.CharCalls == 1 {
		Owner := KL_MarkSynthetic("inflight-fragment-boundary")
		_KSD_Require(KL_ClearSynthetic(Owner), "The exact in-flight synthetic boundary must retire.")
		_KSP.Cuts += 1
	}
	return MF_ShouldFilter()
}

_KSP_Exercise() {
	global _KID, _KSD, _KSP
	_KID.Window := Gui(, "Ergopti owned Unicode scalar roundtrip")
	_KID.Edit := _KID.Window.AddEdit("w340 r4 Multi WantReturn WantTab", "")
	Hook := 0
	PreviousLevel := A_SendLevel
	PrefixIo := InStr(_KID.Mode, "packet-io-") == 1
	Gap := InStr(_KID.Mode, "packet-gap-") == 1
	Units := _KID.Mode == "packet-bmp" ? [0x41] : PrefixIo ? [0x41, 0xD83D, 0xDE00] : [0xD83D, 0xDE00]
	Expected := _KID.Mode == "packet-bmp" ? "A" : (PrefixIo ? "A" : "") . Chr(0x1F600)
	ExpectedLog := Gap ? "" : Expected
	try {
		_KID.Window.Show()
		_KSD_Require(WinGetPID("ahk_id " . _KID.Window.Hwnd) == ProcessExist(), "Only this child may own the native receiver.")
		WinActivate("ahk_id " . _KID.Window.Hwnd)
		_KSD_Require(WinWaitActive("ahk_id " . _KID.Window.Hwnd, , 2), "The exact private receiver must acquire foreground.")
		_KID.Edit.Focus()
		_KID_Target()
		Keystats.initialized := true
		MetricsFilters.secure_field := false
		_KSD_Acquire({App: "owned-native-keystats.exe", Title: "Owned Unicode scalar receiver", Hwnd: _KID.Window.Hwnd})
		_KSD_Require(KL_Hook_RefreshContext(true) && !MF_ShouldFilter(), "The genuine cached privacy owner must admit this public receiver.")
		Hook := InputHook(HookDispatcherConst.INPUT_HOOK_OPTS)
		Hook.KeyOpt("{All}", "+N")
		Hook.NotifyNonText := true
		Hook.OnKeyDown := _KID_Down
		Hook.OnChar := _KID_Char
		OnMessage(0x100, _KID_KeyMessage)
		OnMessage(0x0102, _KPU_CharMessage)
		_KID.Active := true
		Hook.Start()
		_KSD_Require(Hook.InProgress, "The actual native InputHook must be active.")
		SendLevel(2)
		for Index, Unit in Units {
			_KPU_SendUnicode(Unit)
			BoundaryIndex := PrefixIo ? 2 : 1
			if Index != BoundaryIndex || (!Gap && !PrefixIo) || _KID.Mode == "packet-gap-inflight"
				continue
			StartedHigh := A_TickCount
			while _KID.CharCalls < BoundaryIndex && TickElapsed64(StartedHigh) < 2000
				Sleep(5)
			_KSD_Require(_KID.CharCalls == BoundaryIndex && IsObject(Keystats.scalar_fragment)
				&& Keystats.buffer_text == (PrefixIo ? "A" : ""),
				"The actual first high callback must be pending outside every serializable buffer.")
			if PrefixIo {
				Fragment := Keystats.scalar_fragment
				BeforeRows := Keystats._pending_entries.Length
				if _KID.Mode == "packet-io-flush" {
					; The inherited observer wrapper intentionally permits only empty
					; payloads. Call its exact real body for this nonempty flush.
					_KSD_Require(_KSD_NativeFlush(), "The genuine nonempty flush must publish the first accepted batch.")
				} else {
					Detached := _KL_DetachBufferSnapshot()
					_KSD_Require(IsObject(Detached) && _KL_PublishBufferSnapshot(Detached, A_TickCount),
						"The real detached first batch must publish under its unchanged context.")
				}
				_KSD_Require(Keystats._pending_entries.Length == BeforeRows + 1, "Exactly one genuine accepted typing row must be queued.")
				FirstRow := Keystats._pending_entries[BeforeRows + 1]
				_KSD_Require(FirstRow["type"] == "typing" && FirstRow["text"] == "A", "The first batch must contain its real accepted prefix.")
				_KSP.PrefixText := FirstRow["text"]
				_KSP.PrefixJoined := ""
				for PrefixEvent in FirstRow["events"]
					_KSP.PrefixJoined .= PrefixEvent[1]
				_KSD_Require(_KSP.PrefixJoined == "A", "The actual first event batch must preserve the prefix.")
				_KSD_Require(FSWriteCreateDurable(A_Args[2] . "\prefix.json", KL_JsonEncode(FirstRow)),
					"The first genuine batch must cross its actual UTF-8 file boundary before the low unit.")
				_KSD_Require(Keystats.scalar_fragment == Fragment && Keystats.buffer_text == "",
					"I/O alone cannot retire or relabel the pending fragment's original authority.")
			} else {
				switch _KID.Mode {
					case "packet-gap-synth":
						Owner := KL_MarkSynthetic("owned-fragment-boundary")
						_KSD_Require(KL_ClearSynthetic(Owner), "The exact synthetic boundary owner must retire.")
					case "packet-gap-context": KL_InvalidatePasswordFocus()
					case "packet-gap-stop": KL_Hook_InvalidateCapture()
				}
			}
			if _KID.Mode != "packet-gap-private"
				_KSP.Cuts += 1
		}
		SendLevel(PreviousLevel)
		Started := A_TickCount
		while TickElapsed(Started) < 2000 {
			if _KID.NativeDown == Units.Length && _KID.TargetDown == Units.Length
				&& TickElapsed(_KID.LastCallback) >= 100
				break
			Sleep(5)
		}
		_KID_Target()
		if IsObject(_KID.Failure)
			throw _KID.Failure
		_KSD_Require(_KID.NativeDown == Units.Length && _KID.TargetDown == Units.Length
			&& _KID.CharCalls > 0 && _KSD.Errors == 0,
			"The real native receiver and genuine InputHook callbacks must receive all input without hidden errors.")
		_KSD_Require(_KID.Edit.Value == Expected && _KSP.PrefixText . Keystats.buffer_text == ExpectedLog,
			"The native receiver must contain its exact injected text, while logging follows the retained or explicitly revoked owner.")
		Joined := ""
		for Event in Keystats.buffer_events
			Joined .= Event[1]
		_KSD_Require(_KSP.PrefixJoined . Joined == ExpectedLog && Keystats.health_privacy_hits == (_KID.Mode == "packet-gap-private" ? 1 : 0)
			&& KLHook.capture_queue.Length == 0 && !KLHook.capture_owner,
			"The real accepted FIFO must preserve the admitted text and expected privacy count across every actual batch.")
		_KSD_Require((!Gap && !PrefixIo) || _KSP.Cuts == 1, "Every explicit cut must reach its genuine boundary exactly once.")
		_KSD_Require(!IsObject(Keystats.scalar_fragment), "No fragment may remain after the terminal low callback.")
		FileAppend("OBS native-utf16 mode=" . _KID.Mode . " receiver_hex=" . _KSP_Hex(_KID.Edit.Value)
			. " buffer_hex=" . _KSP_Hex(Keystats.buffer_text) . " events_joined_hex=" . _KSP_Hex(Joined)
			. " callback_units=" . _KID.CharUnits . " char_calls=" . _KID.CharCalls
			. " events=" . Keystats.buffer_events.Length . " prefix_hex=" . _KSP_Hex(_KSP.PrefixText) . " cuts=" . _KSP.Cuts . "`n", "*", "UTF-8-RAW")
		; These are the exact accepted events, not invented serializer rows. Both
		; the canonical encoder and the actual native UTF-8 writer remain real.
		; This exercises that boundary, not the rest of the ingest/SQLite pipeline.
		Path := A_Args[2] . "\accepted.json"
		_KSD_Require(FSWriteCreateDurable(Path, KL_JsonEncode(Map("text", Keystats.buffer_text,
			"events", Keystats.buffer_events))), "The accepted record must survive the actual UTF-8 file boundary.")
		Decoded := JsonParse(FSReadStrict(Path))
		Roundtrip := ""
		for Event in Decoded["events"]
			Roundtrip .= Event[1]
		PrefixDecoded := PrefixIo ? JsonParse(FSReadStrict(A_Args[2] . "\prefix.json")) : Map("text", "", "events", [])
		PrefixRoundtrip := ""
		for PrefixEvent in PrefixDecoded["events"]
			PrefixRoundtrip .= PrefixEvent[1]
		FileAppend("OBS native-utf16 roundtrip_hex=" . _KSP_Hex(Roundtrip)
			. " stored_text_hex=" . _KSP_Hex(Decoded["text"]) . "`n", "*", "UTF-8-RAW")
		_KSD_Require(PrefixDecoded["text"] . Decoded["text"] == ExpectedLog && PrefixRoundtrip . Roundtrip == ExpectedLog,
			"The independently serialized accepted batches must reconstruct the admitted Unicode output exactly.")
	} finally {
		_KID.Active := false
		SendLevel(PreviousLevel)
		if IsObject(Hook) {
			Hook.Stop()
			_KSD_Require(!Hook.InProgress, "The exact InputHook must retire before its receiver.")
		}
		OnMessage(0x100, _KID_KeyMessage, 0)
		OnMessage(0x0102, _KPU_CharMessage, 0)
		try _KID.Window.Destroy()
		Keystats.initialized := false
	}
}

if A_Args.Length != 3 || A_Args[3] != "--allow-explicit-owned-edit-unicode-input"
	throw Error("Explicit private native Unicode receiver opt-in is required.")
if !(A_Args[1] == "packet-bmp" || A_Args[1] == "packet-astral"
	|| A_Args[1] == "packet-io-flush" || A_Args[1] == "packet-io-detach"
	|| A_Args[1] == "packet-gap-synth" || A_Args[1] == "packet-gap-context"
	|| A_Args[1] == "packet-gap-stop" || A_Args[1] == "packet-gap-private"
	|| A_Args[1] == "packet-gap-inflight")
	throw Error("A known Unicode scalar vector is required.")
global _KSP := {Cuts: 0, PrefixText: "", PrefixJoined: ""}
global _KSD := {Log: A_Args[2] . "\private.log", Errors: 0, Probes: 0, FlushCalls: 0, LogCalls: 0, Failure: 0}
global _KID := {Mode: A_Args[1], Window: 0, Edit: 0, Active: false, NativeDown: 0, TargetDown: 0,
	CharCalls: 0, CharUnits: "", LastCallback: 0, Failure: 0, ReceiverChars: 0, ReceiverUnits: "", DialogRequests: 0,
	ExpectedVk: 0xE7}
try {
	_KSP_Exercise()
	FileAppend("PASS native-keystats " . _KID.Mode . "`n", "*", "UTF-8-RAW")
	ExitApp(0)
} catch as KSPEntryFailure {
	FileAppend("FAIL native-utf16 " . KSPEntryFailure.Message . " line=" . KSPEntryFailure.Line . "`n", "*", "UTF-8-RAW")
	if FileExist(_KSD.Log)
		FileAppend(FileRead(_KSD.Log, "UTF-8"), "*", "UTF-8-RAW")
	ExitApp(1)
}
