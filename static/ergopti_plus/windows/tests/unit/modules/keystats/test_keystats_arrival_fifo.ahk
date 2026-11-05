; tests/unit/modules/keystats/test_keystats_arrival_fifo.ahk

; ==============================================================================
; MODULE: Keystats Arrival FIFO and Observer Hints
; DESCRIPTION:
; Each keystroke's metadata, synthesis and classification belong to its
; own arrival, the idle timer defers a pending classification, completion
; refusals stay contained, and observer hints honour their barriers.
; ==============================================================================

#Requires AutoHotkey v2.0





; Arrival receipts are classified on the original callback thread, then committed
; in FIFO order. Every fixture owns all state and uses only recording ports.
_KLF_WithState(Body) {
	global _Stub_AppendLogRows, _Stub_AppendLogAccept, _Stub_AppendLogRejectSuspend
	global _Stub_AppendLogHook, _Stub_WpmPushCalls
	Owners := [Keystats, KLHook, KLWatch, KLPasswordCache, MetricsFocusCache, MetricsFilters]
	Fields := [["initialized", "_shutting_down", "lifecycle_generation", "buffer_events", "buffer_text",
		"synth_active", "synth_type", "synth_private", "health_privacy_hits"],
		["last_tick", "last_vk", "last_sc", "last_hint_lifecycle", "capture_queue", "capture_owner", "capture_generation", "capture_stopping", "control_char_echo", "context_transition", "context_stop", "context_observations", "context_observation_head"],
		["is_session_active", "session_started_at", "session_generation", "last_authorized_tick", "is_idle", "idle_started_at", "idle_generation",
		"privacy_interrupted", "privacy_started_at", "session_close", "session_close_draining", "idle_close", "system_events", "system_failure_reported"],
		["generation", "focus_generation"], ["generation", "state"],
		["disabled_apps", "private_browsing", "secure_field", "system_auth"]]
	Saved := []
	for Index, Owner in Owners {
		Values := Map()
		for Field in Fields[Index]
			Values[Field] := Owner.HasOwnProp(Field) ? {present: true, value: Owner.%Field%} : {present: false}
		Saved.Push(Values)
	}
	SavedRows := _Stub_AppendLogRows
	SavedAccept := _Stub_AppendLogAccept
	SavedReject := _Stub_AppendLogRejectSuspend
	SavedHook := _Stub_AppendLogHook
	SavedWpm := _Stub_WpmPushCalls
	try {
		Keystats.initialized := true
		Keystats._shutting_down := false
		Keystats.lifecycle_generation := 100
		Keystats.buffer_events := []
		Keystats.buffer_text := ""
		Keystats.synth_active := 0
		Keystats.synth_type := "none"
		Keystats.synth_private := false
		Keystats.health_privacy_hits := 0
		KLHook.last_tick := 100
		KLHook.last_vk := 0x41
		KLHook.last_sc := 0x1E
		KLHook.control_char_echo := false
		KLHook.context_transition := false
		KLHook.context_stop := false
		KLHook.context_observations := [], KLHook.context_observation_head := 1
		KLHook.last_hint_lifecycle := Keystats.lifecycle_generation
		if KLHook.HasOwnProp("capture_queue") {
			KLHook.capture_queue := []
			KLHook.capture_owner := false
			KLHook.capture_generation := 100
			KLHook.capture_stopping := false
		}
		KLWatch.is_session_active := true
		KLWatch.session_started_at := 100
		KLWatch.last_authorized_tick := 100
		KLWatch.is_idle := false
		KLWatch.idle_started_at := 0
		KLWatch.privacy_interrupted := false
		KLWatch.privacy_started_at := 0
		KLWatch.session_close := false
		KLWatch.session_close_draining := false
		KLWatch.idle_close := false
		KLWatch.system_events := false
		KLWatch.system_failure_reported := false
		KLPasswordCache.generation := 100
		KLPasswordCache.focus_generation := 100
		MetricsFocusCache.generation := 100
		MetricsFocusCache.state := {valid: true, process_name: "owned-fifo.exe", title: "Owned FIFO",
			class: "OwnedFifo", hwnd: 1, last_at: 100, failure_reason: "", timed_out: false}
		MetricsFilters.disabled_apps := Map()
		MetricsFilters.private_browsing := false
		MetricsFilters.secure_field := false
		MetricsFilters.system_auth := false
		_Stub_AppendLogRows := []
		_Stub_AppendLogAccept := true
		_Stub_AppendLogRejectSuspend := false
		_Stub_AppendLogHook := 0
		_Stub_WpmPushCalls := []
		Body.Call()
	} finally {
		for Index, Owner in Owners {
			for Field, Prior in Saved[Index] {
				if Prior.present
					Owner.%Field% := Prior.value
				else if Owner.HasOwnProp(Field)
					Owner.DeleteProp(Field)
			}
		}
		_Stub_AppendLogRows := SavedRows
		_Stub_AppendLogAccept := SavedAccept
		_Stub_AppendLogRejectSuspend := SavedReject
		_Stub_AppendLogHook := SavedHook
		_Stub_WpmPushCalls := SavedWpm
	}
}

_KLF_Allow() {
	return false
}

_KLF_NoShortcut(*) {
	return ""
}

_KLF_Shortcut(Label, *) {
	return Label
}

_KLF_Reenter() {
	KL_Hook_OnChar(0, "b", _KLF_Allow, 1100)
	AssertEqual(0, Keystats.buffer_events.Length,
		"a nested ready receipt must not publish ahead of the outer unready receipt")
	AssertEqual(100, KLHook.last_tick, "classification cannot publish timing out of order")
	return false
}

_KLF_Ordered(Kind) {
	global _Stub_AppendLogRows
	switch Kind {
		case "char": KL_Hook_OnChar(0, "a", _KLF_Reenter, 1000)
		case "special": KL_Hook_OnKeyDown(0, 0x0D, 0x1C, _KLF_Reenter, 1000, _KLF_NoShortcut)
		case "shortcut": KL_Hook_OnKeyDown(0, 0x41, 0x1E, _KLF_Reenter, 1000, _KLF_Shortcut.Bind("Ctrl+A"))
		case "special_shortcut": KL_Hook_OnKeyDown(0, 0x0D, 0x1C, _KLF_Reenter, 1000, _KLF_Shortcut.Bind("Ctrl+Enter"))
	}
	AssertEqual(1100, KLHook.last_tick, "both original arrival timestamps survive ordered processing")
	AssertEqual(1100, KLWatch.last_authorized_tick, "the actual watcher consumes both timestamps in order")
	Rows := Keystats.buffer_events
	if Kind = "shortcut" {
		AssertEqual(1, Rows.Length)
		AssertEqual("b", Rows[1][1])
		AssertEqual(100, Rows[1][2], "shortcut activity owns the prior tick exactly once")
	} else {
		AssertEqual(2, Rows.Length, "both observed tokens must survive without clamp or drop")
		AssertEqual(Kind = "char" ? "a" : "[ENTER]", Rows[1][1])
		AssertEqual(900, Rows[1][2])
		AssertEqual("b", Rows[2][1])
		AssertEqual(100, Rows[2][2])
	}
	if InStr(Kind, "shortcut") {
		AssertEqual(1, _Stub_AppendLogRows.Length, "the actual shortcut publication owner must run")
		AssertEqual("shortcut", _Stub_AppendLogRows[1]["type"])
		AssertEqual(Kind = "shortcut" ? "Ctrl+A" : "Ctrl+Enter", _Stub_AppendLogRows[1]["key"])
	}
}
for _KLF_Kind in ["char", "special", "shortcut", "special_shortcut"]
	Test("keystats arrival FIFO: interrupted " . _KLF_Kind,
		_KLF_WithState.Bind(_KLF_Ordered.Bind(_KLF_Kind)))

_KLF_NewMetadata() {
	KL_Hook_OnKeyDown(0, 0x42, 0x30, _KLF_Allow, 1050, _KLF_NoShortcut)
	KL_Hook_OnChar(0, "b", _KLF_Allow, 1100)
	return false
}

_KLF_Metadata() {
	KL_Hook_OnChar(0, "a", _KLF_NewMetadata, 1000)
	Rows := Keystats.buffer_events
	AssertEqual(2, Rows.Length)
	AssertEqual(0x41, Rows[1][3]["kc"], "outer receipt retains its entry keycode")
	AssertEqual(0x1E, Rows[1][3]["sk"])
	AssertEqual(0x42, Rows[2][3]["kc"], "nested Char pairs with the nested arrived keydown")
	AssertEqual(0x30, Rows[2][3]["sk"])
	AssertEqual(0x42, KLHook.last_vk, "public metadata remains the latest arrived keydown")
	AssertEqual(0x30, KLHook.last_sc)
}
Test("keystats arrival FIFO: metadata belongs to its arrival", _KLF_WithState.Bind(_KLF_Metadata))

_KLF_ChangeSynthetic() {
	Keystats.synth_active := 1
	Keystats.synth_type := "owned-expansion"
	Keystats.synth_private := true
	KL_Hook_OnChar(0, "z", _KLF_Allow, 1100)
	Keystats.synth_active := 0
	Keystats.synth_type := "none"
	Keystats.synth_private := false
	return false
}

_KLF_Synthetic() {
	global PI_MASK_FALLBACK_CHAR
	KL_Hook_OnChar(0, "a", _KLF_ChangeSynthetic, 1000)
	Rows := Keystats.buffer_events
	AssertEqual(2, Rows.Length)
	AssertEqual("a", Rows[1][1])
	AssertFalse(Rows[1][3].Has("s"), "outer manual receipt stays manual")
	AssertEqual(PI_MASK_FALLBACK_CHAR, Rows[2][1])
	AssertEqual(1, Rows[2][3]["s"])
	AssertEqual("owned-expansion", Rows[2][3]["st"])
	AssertEqual(1000, KLWatch.last_authorized_tick, "queued synthetic activity cannot mutate accepted timing")
	AssertEqual(0, KLHook.last_tick, "the final synthetic receipt preserves the original physical-clock reset")
	KL_Hook_OnChar(0, "c", _KLF_Allow, 1200)
	AssertEqual("c", Keystats.buffer_events[3][1])
	AssertEqual(0, Keystats.buffer_events[3][2], "next physical row restarts timing after ordered synthesis")
	AssertEqual(1200, KLHook.last_tick)
}
Test("keystats arrival FIFO: synthesis belongs to its arrival", _KLF_WithState.Bind(_KLF_Synthetic))

_KLF_ChangeFocus() {
	MetricsFocusCache.generation += 1
	return false
}

_KLF_PrivacyDowngrade() {
	KL_Hook_OnChar(0, "a", _KLF_ChangeFocus, 1000)
	AssertEqual(0, Keystats.buffer_events.Length, "a changed identity cannot borrow an ordinary verdict")
	AssertEqual(1000, KLHook.last_tick, "unknown privacy still accounts for physical activity")
	AssertEqual(100, KLWatch.last_authorized_tick, "unknown privacy cannot acquire authorized time")
	AssertTrue(KLWatch.privacy_interrupted)
	AssertEqual(1000, KLWatch.privacy_started_at)
}
Test("keystats arrival FIFO: changed classification identity remains private physical activity",
	_KLF_WithState.Bind(_KLF_PrivacyDowngrade))

_KLF_ChangeLifecycle() {
	Keystats.lifecycle_generation += 1
	KL_Hook_OnChar(0, "b", _KLF_Allow, 1100)
	return false
}

_KLF_Lifecycle() {
	KL_Hook_OnChar(0, "a", _KLF_ChangeLifecycle, 1000)
	AssertEqual(1, Keystats.buffer_events.Length, "revoked old lifecycle cannot publish into the successor")
	AssertEqual("b", Keystats.buffer_events[1][1])
	AssertEqual(1100, KLHook.last_tick)
	AssertEqual(1100, KLWatch.last_authorized_tick)
	AssertFalse(KL_Hook_HasPendingInput(), "revocation cannot strand a drain owner")
}
Test("keystats arrival FIFO: lifecycle revocation leaves successor work intact", _KLF_WithState.Bind(_KLF_Lifecycle))


_KLF_Ordinary(Kind) {
	global _Stub_AppendLogRows
	switch Kind {
		case "char": KL_Hook_OnChar(0, "a", _KLF_Allow, 1000)
		case "special": KL_Hook_OnKeyDown(0, 0x0D, 0x1C, _KLF_Allow, 1000, _KLF_NoShortcut)
		case "shortcut": KL_Hook_OnKeyDown(0, 0x41, 0x1E, _KLF_Allow, 1000, _KLF_Shortcut.Bind("Ctrl+A"))
		case "special_shortcut": KL_Hook_OnKeyDown(0, 0x0D, 0x1C, _KLF_Allow, 1000, _KLF_Shortcut.Bind("Ctrl+Enter"))
	}
	AssertEqual(1000, KLHook.last_tick)
	AssertEqual(1000, KLWatch.last_authorized_tick)
	AssertEqual(Kind = "shortcut" ? 0 : 1, Keystats.buffer_events.Length)
	if Kind != "shortcut"
		AssertEqual(900, Keystats.buffer_events[1][2])
	AssertEqual(InStr(Kind, "shortcut") ? 1 : 0, _Stub_AppendLogRows.Length)
	AssertFalse(KL_Hook_HasPendingInput(), "every completed ordinary receipt releases its lease")
}
for _KLF_Kind in ["char", "special", "shortcut", "special_shortcut"]
	Test("keystats arrival FIFO: ordinary " . _KLF_Kind,
		_KLF_WithState.Bind(_KLF_Ordinary.Bind(_KLF_Kind)))

_KLF_IdleDuringClassification() {
	global _Stub_AppendLogRows
	KL_Watchers_IdleTick(35101)
	AssertFalse(KLWatch.is_idle, "a timer cannot classify inactivity while the just-arrived head is unready")
	AssertEqual(0, _Stub_AppendLogRows.Length, "pending classification cannot publish a premature idle_start")
	return false
}

_KLF_PendingIdle() {
	global _Stub_AppendLogRows
	KL_Hook_OnChar(0, "a", _KLF_IdleDuringClassification, 35100)
	AssertEqual(1, Keystats.buffer_events.Length)
	AssertEqual(35000, Keystats.buffer_events[1][2])
	AssertFalse(KL_Hook_HasPendingInput(), "completion makes later timer checks eligible")
	KL_Watchers_IdleTick(35102)
	AssertFalse(KLWatch.is_idle)
	AssertEqual(0, _Stub_AppendLogRows.Length)
}
Test("keystats arrival FIFO: idle timer defers the pending classification",
	_KLF_WithState.Bind(_KLF_PendingIdle))


_KLF_RecordErgo(Rows, Arguments*) {
	Rows.Push(Arguments)
}

_KLF_BackspaceContract() {
	Rows := []
	Record := _KLF_RecordErgo.Bind(Rows)
	Keystats.buffer_text := "ab"
	KL_Hook_OnChar(0, "c", _KLF_Allow, 1000, Record)
	KL_Hook_OnKeyDown(0, 0x08, 0, _KLF_Allow, 1050, _KLF_NoShortcut, Record)
	AssertEqual(2, Rows.Length, "both actual callback branches must notify ergonomics")
	AssertEqual(3, Rows[1].Length, "Char retains its original three-argument contract")
	AssertEqual(4, Rows[2].Length, "KeyDown retains its explicit Backspace argument")
	AssertEqual(50, Rows[2][1])
	AssertEqual(0x08, Rows[2][2])
	AssertEqual(0, Rows[2][3])
	AssertTrue(Rows[2][4], "the actual Backspace branch must retain deletion accounting")
	AssertEqual("ab", Keystats.buffer_text)
	Meta := Keystats.buffer_events[2][3]
	AssertTrue(Meta.Has("kc") && Meta.Has("sk"), "special-key metadata retains both original keys")
	AssertEqual(0x08, Meta["kc"])
	AssertEqual(0, Meta["sk"], "a zero scancode remains explicitly recorded for KeyDown")
}
Test("keystats arrival FIFO: Backspace ergonomics and zero scancode retain their contracts",
	_KLF_WithState.Bind(_KLF_BackspaceContract))

_KLF_RejectReady(This, Value) {
	throw Error("Owned completion setter refusal.")
}

_KLF_BreakCompletion() {
	Intent := KLHook.capture_queue[1]
	KL_Hook_OnChar(0, "b", _KLF_Allow, 1100)
	Intent.DeleteProp("ready")
	Intent.DefineProp("ready", {Get: (*) => false, Set: _KLF_RejectReady})
	return false
}

_KLF_CompletionRefusal(Kind) {
	if Kind = "char"
		KL_Hook_OnChar(0, "a", _KLF_BreakCompletion, 1000)
	else
		KL_Hook_OnKeyDown(0, 0x0D, 0x1C, _KLF_BreakCompletion, 1000, _KLF_NoShortcut)
	AssertEqual(1, Keystats.buffer_events.Length, "only the failed owned receipt is retired")
	AssertEqual("b", Keystats.buffer_events[1][1], "the ready successor remains drainable")
	AssertEqual(1000, Keystats.buffer_events[1][2])
	AssertEqual(1100, KLHook.last_tick)
	AssertEqual(1100, KLWatch.last_authorized_tick)
	AssertFalse(KL_Hook_HasPendingInput(), "a completion refusal must not wedge the lease")
	KL_Hook_OnChar(0, "c", _KLF_Allow, 1200)
	AssertEqual("c", Keystats.buffer_events[2][1], "subsequent callbacks stay alive after the logged refusal")
	AssertEqual(100, Keystats.buffer_events[2][2])
}
for _KLF_Kind in ["char", "key"]
	Test("keystats arrival FIFO: completion refusal stays contained for " . _KLF_Kind,
		_KLF_WithState.Bind(_KLF_CompletionRefusal.Bind(_KLF_Kind)))

; OnChar has no key arguments. Cached fields are hints scoped to accepted
; capture/logger epochs; these port-driven cases do not qualify native pairing.
_KLF_HintBarrier(Mode) {
	if Mode = "capture"
		KL_Hook_InvalidateCapture()
	else if Mode = "lifecycle"
		Keystats.lifecycle_generation += 1
	else {
		AssertTrue(KL_BeginShutdown(), "the actual shutdown lease must begin")
		AssertFalse(_KL_Hook_CaptureInput("key", "", 0x42, 0x30, _KLF_Allow, 900),
			"shutdown cannot admit a replacement cached identity")
		AssertTrue(KL_CancelShutdown(), "the actual shutdown rollback must own a successor lifecycle")
	}
	Ergonomic := []
	KL_Hook_OnChar(0, "z", _KLF_Allow, 1000, _KLF_RecordErgo.Bind(Ergonomic))
	AssertEqual(1, Keystats.buffer_events.Length, "a public successor Char must still be recorded")
	Meta := Keystats.buffer_events[1][3]
	AssertFalse(Meta.Has("kc"), "a successor Char cannot inherit the prior lifecycle's keycode hint")
	AssertFalse(Meta.Has("sk"), "a successor Char cannot inherit the prior lifecycle's scan hint")
	AssertEqual(1, Ergonomic.Length)
	AssertEqual(3, Ergonomic[1].Length, "the established ergonomic Char signature must remain unchanged")
	AssertEqual(0, Ergonomic[1][2], "unknown key identity remains explicitly unknown")
	AssertEqual(0, Ergonomic[1][3])
	AssertEqual(0, KLHook.last_vk)
	AssertEqual(0, KLHook.last_sc)
	AssertFalse(KL_Hook_HasPendingInput(), "barrier handling must not strand an input owner")
}
for _KLF_HintMode in ["capture", "lifecycle", "shutdown-rollback"]
	Test("keystats observer hints: barrier " . _KLF_HintMode . " (todo49-observer-hints)",
		_KLF_WithState.Bind(_KLF_HintBarrier.Bind(_KLF_HintMode)))

_KLF_DeclinedHint(Mode) {
	switch Mode {
		case "uninitialized": Keystats.initialized := false
		case "shutdown": Keystats._shutting_down := true
		case "stopping": KLHook.capture_stopping := true
	}
	Before := KLHook.capture_queue.Length
	AssertFalse(_KL_Hook_CaptureInput("key", "", 0x42, 0x30, _KLF_Allow, 1000),
		"an inactive callback must not acquire input or metadata ownership")
	AssertEqual(0x41, KLHook.last_vk, "a declined Down cannot overwrite the last admitted hint")
	AssertEqual(0x1E, KLHook.last_sc)
	AssertEqual(100, KLHook.last_hint_lifecycle)
	AssertEqual(Before, KLHook.capture_queue.Length, "declined input must remain outside the FIFO")
}
for _KLF_HintMode in ["uninitialized", "shutdown", "stopping"]
	Test("keystats observer hints: declined " . _KLF_HintMode . " (todo49-observer-hints)",
		_KLF_WithState.Bind(_KLF_DeclinedHint.Bind(_KLF_HintMode)))

_KLF_FreshHint() {
	KL_Hook_InvalidateCapture()
	KL_Hook_OnKeyDown(0, 0x42, 0x30, _KLF_Allow, 950, _KLF_NoShortcut)
	Ergonomic := []
	KL_Hook_OnChar(0, "b", _KLF_Allow, 1000, _KLF_RecordErgo.Bind(Ergonomic))
	AssertEqual(1, Keystats.buffer_events.Length)
	Meta := Keystats.buffer_events[1][3]
	AssertEqual(0x42, Meta["kc"], "a new admitted Down may provide a same-epoch metadata hint")
	AssertEqual(0x30, Meta["sk"])
	AssertEqual(Keystats.lifecycle_generation, KLHook.last_hint_lifecycle)
	AssertEqual(3, Ergonomic[1].Length)
	AssertEqual(0x42, Ergonomic[1][2])
	AssertEqual(0x30, Ergonomic[1][3])
	AssertFalse(KL_Hook_HasPendingInput())
}
Test("keystats observer hints: a newly admitted identity survives unchanged (todo49-observer-hints)",
	_KLF_WithState.Bind(_KLF_FreshHint))


_KLF_BackspaceUnicodeScalar() {
	Ergonomic := []
	Record := _KLF_RecordErgo.Bind(Ergonomic)
	Emoji := Chr(0x1F642)
	KL_Hook_OnChar(0, "é", _KLF_Allow, 1000, Record)
	KL_Hook_OnChar(0, Emoji, _KLF_Allow, 1100, Record)
	AssertEqual("é" . Emoji, Keystats.buffer_text, "the observed supplementary character must reach the buffer intact")
	KL_Hook_OnKeyDown(0, 0x08, 0x0E, _KLF_Allow, 1200, _KLF_NoShortcut, Record)
	AssertEqual("é", Keystats.buffer_text,
		"one Backspace must remove the complete supplementary scalar without leaving a high surrogate")
	Decoded := KL_JsonDecode(KL_JsonEncode(Map("text", Keystats.buffer_text, "events", Keystats.buffer_events)))
	AssertEqual("é", Decoded["text"], "the durable typing payload must contain the same corrected text")
	AssertEqual(Emoji, Decoded["events"][2][1], "the original input event remains intact for replay")
	AssertEqual("[BS]", Decoded["events"][3][1], "deletion remains a single replayable input event")
	KL_Hook_OnKeyDown(0, 0x08, 0x0E, _KLF_Allow, 1300, _KLF_NoShortcut, Record)
	AssertEqual("", Keystats.buffer_text, "BMP deletion must keep removing exactly one character")
	KL_Hook_OnKeyDown(0, 0x08, 0x0E, _KLF_Allow, 1400, _KLF_NoShortcut, Record)
	AssertEqual("", Keystats.buffer_text, "an empty buffer must remain empty")
	KL_Hook_OnChar(0, Emoji, _KLF_Allow, 1500, Record)
	KL_Hook_OnKeyDown(0, 0x08, 0x0E, _KLF_Allow, 1600, _KLF_NoShortcut, Record)
	AssertEqual("", Keystats.buffer_text, "an emoji at the start of the buffer must disappear completely")
	AssertEqual(7, Keystats.buffer_events.Length, "Unicode correction cannot lose or duplicate observed events")
	AssertFalse(KL_Hook_HasPendingInput(), "Unicode correction must release the arrival owner")
}
Test("keystats input: Backspace preserves complete Unicode scalars (keystats-backspace-unicode)",
	_KLF_WithState.Bind(_KLF_BackspaceUnicodeScalar))

; The pause and session-reset sequences drive this same hook, so they share its
; reachability from the runner.
#Include test_keystats_collection.ahk

_KLF_SyntheticSessionBoundary(Mode) {
	global _Stub_AppendLogRows
	KL_Hook_OnChar(0, "a", _KLF_ChangeSynthetic, 1000)
	AssertEqual(0, KLHook.last_tick, "the real synthetic callback retires the key delay clock")
	AssertEqual(1000, KLWatch.last_authorized_tick, "the real manual callback retains accepted session activity")
	AssertTrue(KLWatch.is_session_active)
	ExpectedDuration := 900
	if Mode == "pointer-reset" {
		AssertTrue(KL_Watchers_OnPointer(0, 1200), "actual pointer activity must extend the existing session")
		ExpectedDuration := 1100
	}
	Resets := []
	if Mode == "idle"
		KL_Watchers_IdleTick(1000 + KLWatchConst.SESSION_TIMEOUT_MS + 1)
	else
		AssertTrue(KL_ResetSession(() => true, 0, () => Resets.Push(true)),
			"the genuine session closer must accept reset after a synthetic clock retirement")
	AssertFalse(KLWatch.is_session_active, "the session must close without a subsequent manual key")
	AssertFalse(KLWatch.is_idle, "paired idle state must retire with the session")
	Ends := []
	for Row in _Stub_AppendLogRows
		if Row["type"] == "session_end"
			Ends.Push(Row)
	AssertEqual(1, Ends.Length, "the recording queue boundary must receive one session end")
	AssertEqual(ExpectedDuration, Ends[1]["duration_ms"], "duration uses accepted activity rather than the zero sentinel")
	AssertEqual(Mode == "idle" ? 0 : 1, Resets.Length, "explicit reset acknowledges WPM exactly once")
	AssertEqual(0, KLHook.last_tick, "session closure preserves the next physical key's zero-delay restart")
}
for _KLF_SessionMode in ["idle", "reset", "pointer-reset"]
	Test("keystats session: synthetic clock retirement supports " . _KLF_SessionMode,
		_KLF_WithState.Bind(_KLF_SyntheticSessionBoundary.Bind(_KLF_SessionMode)))

_KLF_ZeroSessionClock() {
	global _Stub_AppendLogRows
	KLHook.last_tick := 0
	KLWatch.last_authorized_tick := 0
	KLWatch.session_started_at := 0
	KL_Watchers_IdleTick(KLWatchConst.SESSION_TIMEOUT_MS + 1)
	AssertFalse(KLWatch.is_session_active, "an accepted session at native tick zero can still expire")
	AssertEqual(3, _Stub_AppendLogRows.Length, "idle start, idle end and session end are paired")
	AssertEqual(0, _Stub_AppendLogRows[3]["duration_ms"], "zero elapsed session time is valid")
}
Test("keystats session: tick zero remains a valid accepted session boundary",
	_KLF_WithState.Bind(_KLF_ZeroSessionClock))


; Resolve the actual declaration once by authored-source identity, not a pinned path.
_KID_ClassOwner(ClassName) {
	global _DriverDir
	Owners := []
	for Path in _DriverProductionSourceCensus(_DriverDir).Paths {
		Text := FileRead(Path, "UTF-8")
		Mask := _DriverMaskNonCode(&Text)
		if RegExMatch(Mask, "m)^\h*class\h+" . ClassName . "\b\s*\{")
			Owners.Push(Path)
	}
	AssertEqual(1, Owners.Length, "The actual native dispatcher constants must have exactly one authored class declaration")
	return Owners[1]
}

; Actual keyboard callbacks are fed by one real InputHook in an owned native Edit.
_KID_ChildSource() {
	global _DriverDir
	Source := _KSD_ChildSource()
	Footer := "#Include " . _DriverDir . "\tests\fixtures\switch_destination_privacy_owner_body.ahk`n"
	AssertEqual(Footer, SubStr(Source, StrLen(Source) - StrLen(Footer) + 1), "The actual KSD source exposes its one fixture footer")
	Source := SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
	Fixture := FileRead(_DriverDir . "\tests\fixtures\switch_destination_privacy_owner_body.ahk", "UTF-8")
	Entry := "_KSD_Main()"
	Fixture := RTrim(Fixture, "`r`n")
	AssertEqual(Entry, SubStr(Fixture, StrLen(Fixture) - StrLen(Entry) + 1))
	Fixture := SubStr(Fixture, 1, StrLen(Fixture) - StrLen(Entry))
	; Its real privacy acquisition, log observation and unchanged empty flush
	; helpers remain available; only the old test entry call is omitted.
	Source .= Fixture . "`n"
	for Spec in [["KL_CommitPwCache", "KLPasswordCache"], ["", "HookDispatcherConst"]] {
		Owner := Spec[1] == "" ? _KID_ClassOwner(Spec[2])
			: _DriverProductionFileForSymbol(Spec[1], _DriverDir)
		AssertTrue(Owner != "")
		AssertTrue(RegExMatch(FileRead(Owner, "UTF-8"), "ms)^class " . Spec[2] . " \{.*?^\}", &Definition) > 0)
		Source .= Definition[0] . "`n"
	}
	Owner := _DriverProductionFileForSymbol("KL_Hook_OnChar", _DriverDir)
	AssertTrue(RegExMatch(FileRead(Owner, "UTF-8"), "ms)^global KLHOOK_SPECIAL := Map\(.*?^\)", &Specials) > 0)
	Source .= Specials[0] . "`n"
	for Symbol in ["KL_Hook_NoteActivity", "KL_Hook_HasPendingInput", "_KL_Hook_CaptureInput",
		"_KL_Hook_InputLifecycleCurrent", "_KL_Hook_PrepareInput", "_KL_Hook_InputCurrent",
		"_KL_Hook_InvalidateTabInput", "_KL_Hook_FinishInput", "_KL_Hook_CompleteInput",
		"_KL_Hook_DrainInput", "_KL_Hook_CommitInput", "KL_Hook_OnChar", "KL_Hook_OnKeyDown",
		"KL_Hook_OnKeyUp", "KL_Hook_RecordedChar", "_KL_CaptureLlmJournalPrivacy", "_KL_LlmJournalPrivacyStillCurrent",
		"KL_InvalidatePasswordFocus", "KLW_PopLast"] {
		Body := _DriverFuncBody(Symbol)
		AssertTrue(Body != "", "The actual callback graph requires its genuine definition: " . Symbol)
		Source .= Body . "`n"
	}
	return Source . "#Include " . _DriverDir . "\tests\fixtures\keystats_native_key_char_body.ahk`n"
}

_KID_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_native_key_char_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Creation := FSCreateDirectoryExclusiveStrict(Directory)
	AssertTrue(Creation is Integer && Creation == 1, "The child must exclusively acquire its directory before writing or recursive cleanup.")
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _KID_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory, "--allow-explicit-owned-edit-sendevent"], _KSD_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact native-keyboard child did not settle within its 15000 ms deadline.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := (Receipt is Integer) && Receipt == 1
			if Retired
				DirDelete(Directory, true)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				RetirementDebt := {Handle: Handle, Directory: Directory}
			Critical(PreviousCritical)
		}
	}
	try {
		if State.Calls == 1 {
			; The tree adapter combines its native stdout/stderr captures. This is
			; not an independently measured stderr channel.
			for Line in StrSplit(State.Output, "`n", "`r")
				if Line != ""
					_TestPrint("# native-keystats-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS native-keystats " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
	return AtDeadline.Output
}

for _KID_Mode in ["letter", "backspace", "enter", "tab"]
	Test("Keystats real InputHook: " . _KID_Mode . " records one delivered native keystroke (keystats-native-key-char-owner)",
		_KID_Case.Bind(_KID_Mode))

_KPU_ChildSource() {
	global _DriverDir
	Source := _KID_ChildSource()
	Footer := "#Include " . _DriverDir . "\tests\fixtures\keystats_native_key_char_body.ahk`n"
	AssertEqual(Footer, SubStr(Source, StrLen(Source) - StrLen(Footer) + 1))
	return SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
		. "#Include " . _DriverDir . "\tests\fixtures\keystats_unicode_packet_owner_body.ahk`n"
}

_KPU_Case(Mode, SourceFn := unset) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_native_unicode_packet_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Creation := FSCreateDirectoryExclusiveStrict(Directory)
	AssertTrue(Creation is Integer && Creation == 1, "The child must exclusively acquire its directory before writing or recursive cleanup.")
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		Subject := IsSet(SourceFn) ? SourceFn.Call() : _KPU_ChildSource()
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . Subject) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory, "--allow-explicit-owned-edit-unicode-input"], _KSD_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact native-keyboard child did not settle within its 15000 ms deadline.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := (Receipt is Integer) && Receipt == 1
			if Retired
				DirDelete(Directory, true)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				RetirementDebt := {Handle: Handle, Directory: Directory}
			Critical(PreviousCritical)
		}
	}
	try {
		if State.Calls == 1 {
			; The tree adapter combines its native stdout/stderr captures. This is
			; not an independently measured stderr channel.
			for Line in StrSplit(State.Output, "`n", "`r")
				if Line != ""
					_TestPrint("# native-keystats-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS native-keystats " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
	return AtDeadline.Output
}

for _KPU_Mode in ["packet-lf", "packet-tab"]
	Test("Keystats real Unicode packet: " . _KPU_Mode . " retains standalone control text (keystats-native-unicode-packet)",
		_KPU_Case.Bind(_KPU_Mode))


; These are public-callback protocol controls, not fabricated native-delivery
; proof. The four existing child-owned real InputHook cases remain unchanged.
_KCE_ReenterCharThenRelease(Hook, Character, Vk, Sc) {
	KL_Hook_OnChar(Hook, Character, _KLF_Allow, 1001)
	KL_Hook_OnKeyUp(Hook, Vk, Sc)
	return false
}

_KCE_Run(Mode) {
	Hook := InputHook("V L0 I1") ; genuine identity; never started by protocol tests
	if Mode == "char-only" {
		KL_Hook_OnChar(Hook, "`n", _KLF_Allow, 1000)
		AssertEqual(1, Keystats.buffer_events.Length)
		AssertEqual("`n", Keystats.buffer_events[1][1])
		AssertEqual("`n", Keystats.buffer_text)
		return
	}
	Vk := Mode == "reenter-tab" ? 0x09 : 0x0D
	Sc := Vk == 0x09 ? 0x0F : 0x1C
	Char := Vk == 0x09 ? "`t" : "`n"
	if InStr(Mode, "reenter-") == 1 {
		KL_Hook_OnKeyDown(Hook, Vk, Sc, _KCE_ReenterCharThenRelease.Bind(Hook, Char, Vk, Sc), 1000, _KLF_NoShortcut)
		AssertEqual(1, Keystats.buffer_events.Length,
			"A queued native echo retains its exact predecessor after a later KeyUp during classification")
		AssertEqual(Vk == 0x09 ? "[TAB]" : "[ENTER]", Keystats.buffer_events[1][1])
		AssertEqual(Char, Keystats.buffer_text)
		return
	}
	KL_Hook_OnKeyDown(Hook, Vk, Sc, _KLF_Allow, 1000, _KLF_NoShortcut)
	if Mode == "modifier-release" {
		KL_Hook_OnKeyUp(Hook, 0x10, 0x2A)
		KL_Hook_OnChar(Hook, Char, _KLF_Allow, 1002)
		AssertEqual(1, Keystats.buffer_events.Length,
			"An unrelated modifier release cannot revoke a pending named key echo")
		AssertEqual("[ENTER]", Keystats.buffer_events[1][1])
		AssertEqual("`n", Keystats.buffer_text)
		return
	}
	switch Mode {
		case "released":
			KL_Hook_OnKeyUp(Hook, Vk, Sc)
		case "packet-key":
			KL_Hook_OnKeyDown(Hook, 0xE7, 0, _KLF_Allow, 1001, _KLF_NoShortcut)
		case "different-hook":
			Hook := InputHook("V L0 I1")
		case "multi-char":
			Char := "`nx"
		case "one-use":
			KL_Hook_OnChar(Hook, Char, _KLF_Allow, 1001)
		default:
			throw Error("Unknown private control-char protocol mode.")
	}
	KL_Hook_OnChar(Hook, Char, _KLF_Allow, 1002)
	AssertEqual(2, Keystats.buffer_events.Length,
		"Only a one-use exact native named-key echo may be discarded; standalone payloads remain")
	AssertEqual("[ENTER]", Keystats.buffer_events[1][1])
	AssertEqual(Char, Keystats.buffer_events[2][1])
	AssertEqual("`n" . Char, Keystats.buffer_text)
}

for _KCE_Mode in ["char-only", "modifier-release", "released", "packet-key", "different-hook", "multi-char", "one-use", "reenter-enter", "reenter-tab"]
	Test("Keystats named control echo: " . _KCE_Mode . " preserves exact FIFO ownership (keystats-control-char-echo)",
		_KLF_WithState.Bind(_KCE_Run.Bind(_KCE_Mode)))


_KSP_ChildSource() {
	global _DriverDir
	Source := _KPU_ChildSource()
	Footer := "#Include " . _DriverDir . "\tests\fixtures\keystats_unicode_packet_owner_body.ahk`n"
	AssertEqual(Footer, SubStr(Source, StrLen(Source) - StrLen(Footer) + 1))
	Source := SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
	Fixture := FSReadStrict(_DriverDir . "\tests\fixtures\keystats_unicode_packet_owner_body.ahk")
	Start := InStr(Fixture, "_KID_Exercise() {")
	AssertTrue(Start > 0 && InStr(Fixture, "_KID_Exercise() {", , Start + 1) == 0,
		"The existing native fixture has one exact exercise boundary")
	; Retain its real native SendInput/WM_CHAR/receiver observer and wrappers
	; delegating the genuine production callbacks, without the old test entry.
	Source .= SubStr(Fixture, 1, Start - 1)
	for Symbol in ["JsonStringLiteral", "KL_JsonEncode", "FSWriteCreateDurable"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "" && _DriverIsProductionSource(Owner), "The actual codec/I/O owner must exist: " . Symbol)
		Source .= "#Include " . Owner . "`n"
	}
	return Source . "#Include " . _DriverDir . "\tests\fixtures\keystats_utf16_packet_body.ahk`n"
}

for _KSP_Mode in ["packet-bmp", "packet-astral"]
	Test("Keystats native Unicode record: " . _KSP_Mode . " preserves accepted output across JSON/UTF-8 (keystats-native-utf16-packet-roundtrip)",
		_KPU_Case.Bind(_KSP_Mode, _KSP_ChildSource))


_KSB_ChildSource() {
	global _DriverDir
	Source := _KPU_ChildSource()
	Footer := "#Include " . _DriverDir . "\tests\fixtures\keystats_unicode_packet_owner_body.ahk`n"
	AssertEqual(Footer, SubStr(Source, StrLen(Source) - StrLen(Footer) + 1))
	Source := SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
	Fixture := FSReadStrict(_DriverDir . "\tests\fixtures\keystats_unicode_packet_owner_body.ahk")
	Start := InStr(Fixture, "_KID_Exercise() {")
	AssertTrue(Start > 0 && InStr(Fixture, "_KID_Exercise() {", , Start + 1) == 0)
	return Source . SubStr(Fixture, 1, Start - 1)
		. "#Include " . _DriverDir . "\tests\fixtures\keystats_high_backspace_body.ahk`n"
}
for _KSB_Mode in ["plain", "high"]
	Test("Keystats native Backspace after " . _KSB_Mode . " preserves the actual owned Edit (keystats-native-high-backspace)",
		_KPU_Case.Bind(_KSB_Mode, _KSB_ChildSource))


_KSX_ChildSource() {
	global _DriverDir
	Source := _KSB_ChildSource()
	Footer := "#Include " . _DriverDir . "\tests\fixtures\keystats_high_backspace_body.ahk`n"
	AssertEqual(Footer, SubStr(Source, StrLen(Source) - StrLen(Footer) + 1))
	Source := SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
	for Symbol in ["KL_MarkSynthetic", "KL_ClearSynthetic"] {
		if !RegExMatch(Source, "m)^" . Symbol . "\(") {
			Body := _DriverFuncBody(Symbol)
			AssertTrue(Body != "", "The native revocation requires its genuine production owner: " . Symbol)
			Source .= Body . "`n"
		}
	}
	return Source . "#Include " . _DriverDir . "\tests\fixtures\keystats_revoked_high_backspace_body.ahk`n"
}
for _KSX_Mode in ["synth-revoked", "focus-invalidated", "two-highs"]
	Test("Keystats native omitted-unit history: " . _KSX_Mode . " preserves both successive Backspaces (keystats-native-revoked-high-backspace)",
		_KPU_Case.Bind(_KSX_Mode, _KSX_ChildSource))
