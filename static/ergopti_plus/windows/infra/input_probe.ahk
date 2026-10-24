; infra/input_probe.ahk

; ==============================================================================
; MODULE: Input Probe
; DESCRIPTION:
; Two opt-in, one-click checks of the Debug menu that settle the open questions
; of the Windows input-hook architecture with real measurements:
;   - "Measure SendEvent vs SendInput": types the shapes the driver really sends
;     (hotstring expansion burst, paste, prediction, a rival key during the
;     send) into a window the check owns, once per send primitive, and records
;     exactness, lost and interleaved keys and latency.
;   - "Record keyboard hook order": records which of two low-level keyboard
;     hooks sees a key first, before and after a SendInput, whose rehook moves
;     AutoHotkey's hook to the front of the chain.
; The driver's behaviour is unchanged: nothing here is reachable except from the
; two menu rows.
;
; FEATURES & RATIONALE:
; 1. Controlled target: every key goes into an Edit of a window the check opens,
;    owns and checks as foreground and focused before each repetition. The
;    check refuses to start while a modifier key or Caps Lock is on, or while the
;    driver is paused (a pause disarms the hotkey the hook check relies on).
; 2. Privacy: the evidence record holds counts, timings and enumerated states
;    only. The synthetic payloads are never written to the log.
; 3. Pure cores: the classification of what reached the Edit, the percentiles
;    and the hook verdict are plain functions, replayed by the unit suite.
; 4. The hook check detects the order by suppression. Its test hook is installed
;    after AutoHotkey's, so it runs first and sees the probe key; once a
;    SendInput has reinstalled AutoHotkey's hook, AutoHotkey runs first and its
;    hotkey swallows the key before the test hook can see it. When another
;    AutoHotkey keyboard hook runs, SendInput falls back to SendEvent and
;    nothing moves: the record says so ("rehook=no").
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Constants and state =======
; ======================================
; ======================================

; Logger tag of every line the checks write; the maintainer filters on it.
global INPUT_PROBE_TAG := "InputProbe"

; Repetitions of each scenario under each send primitive.
global INPUT_PROBE_REPS := 8

; How long one repetition may take to show its exact text.
global INPUT_PROBE_SETTLE_TIMEOUT_MS := 2000

; Time given to a rival key to land before the text is judged.
global INPUT_PROBE_RIVAL_WAIT_MS := 150

; The key a simulated rival typist sends in the middle of the burst.
global INPUT_PROBE_RIVAL_CHAR := "#"

; The two send primitives under comparison.
global INPUT_PROBE_MODES := ["SendInput", "SendEvent"]

; The hook check's probe key: F24, which no layout, shortcut or tap-hold of the
; driver uses. Virtual key and scan code are both pinned because AutoHotkey's
; hook matches a key declared by scan code on the scan code alone.
global INPUT_PROBE_HOOK_VK := 0x87
global INPUT_PROBE_HOOK_SC := 0x76
global INPUT_PROBE_HOOK_KEYS := "{vk87sc076}"
global INPUT_PROBE_HOOK_HOTKEY := "*SC076"

; How long the hook check waits for the hotkey to fire after one injected key.
global INPUT_PROBE_HOOK_WAIT_MS := 500

; At most one check runs at a time.
global _InputProbeBusy := false

; Counters the hook callback and the probe hotkey increment.
global _InputProbeHookSeen := 0
global _InputProbeHookFired := 0





; ============================================
; ============================================
; ======= 2/ Pure helpers (unit suite) =======
; ============================================
; ============================================

; Sorted copy of a numeric array (Array.Sort does not exist in AutoHotkey 2.0).
; @param Values {Array}
; @returns {Array}
InputProbe_SortedCopy(Values) {
	Sorted := []
	for Value in Values {
		Index := Sorted.Length
		Sorted.Push(Value)
		while (Index >= 1 && Sorted[Index] > Value) {
			Sorted[Index + 1] := Sorted[Index]
			Index -= 1
		}
		Sorted[Index + 1] := Value
	}
	return Sorted
}

; Nearest-rank percentile of a numeric array.
; @param Values {Array}
; @param Percent {Number} 0 to 100.
; @returns {Number} 0 for an empty array.
InputProbe_Percentile(Values, Percent) {
	if (Values.Length = 0)
		return 0
	Sorted := InputProbe_SortedCopy(Values)
	Rank := Ceil(Percent / 100 * Sorted.Length)
	if (Rank < 1)
		Rank := 1
	if (Rank > Sorted.Length)
		Rank := Sorted.Length
	return Sorted[Rank]
}

; Judges the text that reached the target against the text that should have.
; A rival key sent in the middle of the burst is exact when it landed after the
; whole burst and interleaved when it landed inside it.
; @param Expected {String} What the burst alone should leave.
; @param Actual {String} What the Edit holds.
; @param Rival {String} The rival key, "" when the scenario has none.
; @returns {Map} kind = ok | lost | interleaved | garbled, lost = missing count.
InputProbe_ClassifyText(Expected, Actual, Rival := "") {
	Result := Map("kind", "ok", "lost", 0)
	if (Rival == "") {
		if (Actual == Expected)
			return Result
		Cleaned := Actual
	} else {
		if (Actual == Expected . Rival)
			return Result
		Cleaned := StrReplace(Actual, Rival, "")
		if (Cleaned == Expected && InStr(Actual, Rival)) {
			Result["kind"] := "interleaved"
			return Result
		}
	}
	if (StrLen(Cleaned) < StrLen(Expected)) {
		Result["kind"] := "lost"
		Result["lost"] := StrLen(Expected) - StrLen(Cleaned)
		return Result
	}
	Result["kind"] := "garbled"
	return Result
}

; Folds the repetitions of one scenario under one primitive into a row.
; @param Scenario {String}
; @param Mode {String}
; @param Reps {Array} Maps { kind, lost, ret_us, settle_us } (settle_us -1 = none).
; @returns {Map}
InputProbe_SummarizeRow(Scenario, Mode, Reps) {
	Row := Map("scenario", Scenario, "mode", Mode, "n", Reps.Length, "exact", 0,
		"lost", 0, "interleaved", 0, "garbled", 0, "timeout", 0)
	Settles := []
	Returns := []
	for Rep in Reps {
		switch Rep["kind"] {
			case "ok":
				Row["exact"] += 1
			case "lost":
				Row["lost"] += Rep["lost"]
			case "interleaved":
				Row["interleaved"] += 1
			default:
				Row["garbled"] += 1
		}
		if (Rep["settle_us"] < 0)
			Row["timeout"] += 1
		else
			Settles.Push(Rep["settle_us"])
		Returns.Push(Rep["ret_us"])
	}
	Row["settle_med_us"] := InputProbe_Percentile(Settles, 50)
	Row["settle_p95_us"] := InputProbe_Percentile(Settles, 95)
	Row["settle_max_us"] := InputProbe_Percentile(Settles, 100)
	Row["ret_med_us"] := InputProbe_Percentile(Returns, 50)
	return Row
}

; Whether a row proves the primitive exact. The rival scenario is evidence, not
; a requirement: an interleaved rival key is the very thing it measures.
; @param Row {Map}
; @returns {Boolean}
InputProbe_RowPasses(Row) {
	if (Row["scenario"] == "rival")
		return true
	return Row["exact"] == Row["n"]
}

; Compact evidence line of one row. Counts and timings only.
; @param Row {Map}
; @returns {String}
InputProbe_RowRecord(Row) {
	return Format("send_compare scenario={1} mode={2} n={3} exact={4} lost={5} interleaved={6}"
		. " garbled={7} timeout={8} return_med_us={9} settle_med_us={10} settle_p95_us={11}"
		. " settle_max_us={12}", Row["scenario"], Row["mode"], Row["n"], Row["exact"],
		Row["lost"], Row["interleaved"], Row["garbled"], Row["timeout"], Row["ret_med_us"],
		Row["settle_med_us"], Row["settle_p95_us"], Row["settle_max_us"])
}

; Which hook ran first in one phase of the hook check.
; The probe hotkey must have fired, or the phase proves nothing.
; @param Seen {Integer} Times the test hook saw the key.
; @param Fired {Integer} Times AutoHotkey's hotkey fired.
; @returns {String} test_first | ahk_first | inconclusive
InputProbe_HookPhaseOrder(Seen, Fired) {
	if (Fired < 1)
		return "inconclusive"
	return Seen >= 1 ? "test_first" : "ahk_first"
}

; Verdict of the whole hook check.
; @param Before {Map} seen, fired before the SendInput.
; @param During {Map} seen, fired while the SendInput ran.
; @param After {Map} seen, fired after it.
; @param Control {Map} seen, fired after the test hook was installed again.
; @returns {Map} before, after, control, changed (yes|no|unknown), rehook
;   (yes|no), conclusive (Boolean).
InputProbe_HookVerdict(Before, During, After, Control) {
	Verdict := Map()
	Verdict["before"] := InputProbe_HookPhaseOrder(Before["seen"], Before["fired"])
	Verdict["after"] := InputProbe_HookPhaseOrder(After["seen"], After["fired"])
	Verdict["control"] := InputProbe_HookPhaseOrder(Control["seen"], Control["fired"])
	; AutoHotkey's hook is removed for the duration of a real SendInput, so its
	; hotkey cannot fire; a hotkey that fires means SendInput fell back to
	; SendEvent because another AutoHotkey keyboard hook runs.
	Verdict["rehook"] := During["fired"] < 1 ? "yes" : "no"
	if (Verdict["before"] == "test_first" && Verdict["after"] == "ahk_first")
		Verdict["changed"] := "yes"
	else if (Verdict["before"] == "test_first" && Verdict["after"] == "test_first")
		Verdict["changed"] := "no"
	else
		Verdict["changed"] := "unknown"
	Verdict["conclusive"] := Verdict["before"] == "test_first"
		&& Verdict["control"] == "test_first" && Verdict["after"] != "inconclusive"
	return Verdict
}

; Compact evidence line of the hook check. Counts and enumerated states only.
; @param Before {Map}
; @param During {Map}
; @param After {Map}
; @param Control {Map}
; @param Verdict {Map}
; @returns {String}
InputProbe_HookRecord(Before, During, After, Control, Verdict) {
	return Format("hook_order before={1}(seen={2},fired={3}) during_sendinput(seen={4},fired={5})"
		. " after={6}(seen={7},fired={8}) control={9}(seen={10},fired={11}) changed={12}"
		. " rehook={13} conclusive={14}", Verdict["before"], Before["seen"], Before["fired"],
		During["seen"], During["fired"], Verdict["after"], After["seen"], After["fired"],
		Verdict["control"], Control["seen"], Control["fired"], Verdict["changed"],
		Verdict["rehook"], Verdict["conclusive"] ? 1 : 0)
}





; ============================================
; ============================================
; ======= 3/ Shared plumbing of the checks ===
; ============================================
; ============================================

; Why a check must not start now.
; @returns {String} "" when it may start, else busy | paused | keys_held.
_IP_Admission() {
	global _InputProbeBusy
	if _InputProbeBusy
		return "busy"
	if A_IsSuspended
		return "paused"
	for KeyName in ["Ctrl", "Alt", "Shift", "LWin", "RWin", "SC138"] {
		if GetKeyState(KeyName, "P")
			return "keys_held"
	}
	if GetKeyState("CapsLock", "T")
		return "keys_held"
	return ""
}

; Opens the window the check types into and makes it the foreground window.
; @returns {Map|Integer} { gui, edit }, 0 when it could not take the focus.
_IP_OpenTarget() {
	Window := Gui("+AlwaysOnTop", WindowTitle(t("input_probe.title")))
	Field := Window.AddEdit("w560 r6")
	Window.Show("w600")
	WinActivate("ahk_id " . Window.Hwnd)
	if !WinWaitActive("ahk_id " . Window.Hwnd, , 3) {
		Window.Destroy()
		return 0
	}
	Field.Focus()
	return Map("gui", Window, "edit", Field)
}

; Whether the target still owns the keyboard.
; @param Target {Map}
; @returns {Boolean}
_IP_TargetReady(Target) {
	return DllCall("GetForegroundWindow", "Ptr") == Target["gui"].Hwnd
		&& DllCall("GetFocus", "Ptr") == Target["edit"].Hwnd
}

; Replaces the Edit's text and puts the caret at its end.
; @param Target {Map}
; @param Text {String}
_IP_Reset(Target, Text) {
	Target["edit"].Value := Text
	Length := StrLen(Text)
	SendMessage(0xB1, Length, Length, Target["edit"].Hwnd)
}

; Sends Keys through the named primitive at SendLevel 0 like the driver's own
; output, optionally as the uninterruptible transaction the hotstring burst is.
; @param Keys {String}
; @param Mode {String} SendInput | SendEvent
; @param Atomic {Boolean} Hold Critical across the send.
_IP_Send(Keys, Mode, Atomic) {
	PreviousLevel := A_SendLevel
	SendLevel(0)
	PreviousCritical := Atomic ? Critical("On") : 0
	try {
		if (Mode == "SendInput")
			SendInput(Keys)
		else
			SendEvent(Keys)
	} finally {
		if Atomic
			Critical(PreviousCritical)
		SendLevel(PreviousLevel)
	}
	return true
}

; Sends Keys through the TextSender funnel with its primitive swapped for Mode:
; the path the predictions take.
; @param Keys {String}
; @param Mode {String}
_IP_SendThroughFunnel(Keys, Mode) {
	global _AHK_SendInput
	PreviousCritical := Critical("On")
	Saved := _AHK_SendInput
	_AHK_SendInput := (Payload) => (Mode == "SendInput" ? SendInput(Payload) : SendEvent(Payload))
	try
		return _TextSenderSendInput(Keys, "input probe", true)
	finally {
		_AHK_SendInput := Saved
		Critical(PreviousCritical)
	}
}

; Sends the simulated rival key from a timer, the way another thread of the
; driver would while an interruptible burst is still being typed.
_IP_RivalFire() {
	global INPUT_PROBE_RIVAL_CHAR
	SendEvent("{Text}" . INPUT_PROBE_RIVAL_CHAR)
}

; Reads the performance counter for the probe's own stopwatch. Not
; _IP_Now(): that opens a hot-path profiler segment, which the profiler
; contract requires to be closed and reported, and a probe timing is neither.
; @returns {Integer} Raw QPC ticks.
_IP_Now() {
	Counter := 0
	DllCall("QueryPerformanceCounter", "Int64*", &Counter)
	return Counter
}

; Ticks to microseconds.
; @param Ticks {Integer} QPC ticks.
; @param Frequency {Integer} QPC frequency.
; @returns {Integer}
_IP_Micros(Ticks, Frequency) {
	return Ticks * 1000000 // Frequency
}

; Runs one repetition of a scenario under one primitive.
; @param Target {Map}
; @param Spec {Map} prefill, expected, rival, atomic, send (callable taking Mode).
; @param Mode {String}
; @param Frequency {Integer} QPC frequency.
; @returns {Map} kind, lost, ret_us, settle_us; kind "foreground" = abort.
_IP_RunRep(Target, Spec, Mode, Frequency) {
	global INPUT_PROBE_SETTLE_TIMEOUT_MS, INPUT_PROBE_RIVAL_WAIT_MS
	_IP_Reset(Target, Spec["prefill"])
	if !_IP_TargetReady(Target)
		return Map("kind", "foreground", "lost", 0, "ret_us", 0, "settle_us", -1)
	Expected := Spec["expected"]
	Rival := Spec["rival"]
	Start := _IP_Now()
	if (Rival != "")
		SetTimer(_IP_RivalFire, -1)
	Spec["send"].Call(Mode)
	ReturnTicks := _IP_Now() - Start
	SettleTicks := -1
	if (Rival == "") {
		Deadline := Start + Frequency * INPUT_PROBE_SETTLE_TIMEOUT_MS // 1000
		while (_IP_Now() < Deadline) {
			if (Target["edit"].Value == Expected) {
				SettleTicks := _IP_Now() - Start
				break
			}
			Sleep(-1)
		}
	} else {
		Sleep(INPUT_PROBE_RIVAL_WAIT_MS)
		SettleTicks := _IP_Now() - Start
	}
	Judged := InputProbe_ClassifyText(Expected, Target["edit"].Value, Rival)
	return Map("kind", Judged["kind"], "lost", Judged["lost"],
		"ret_us", _IP_Micros(ReturnTicks, Frequency),
		"settle_us", SettleTicks < 0 ? -1 : _IP_Micros(SettleTicks, Frequency))
}

; The scenarios of the send comparison. Payloads are synthetic and mix ASCII,
; accented letters, a narrow no-break space and a euro sign so that the Unicode
; route is exercised; none of it is ever logged.
; @returns {Array} Maps { id, spec }.
_IP_Scenarios() {
	global INPUT_PROBE_RIVAL_CHAR
	Replacement := "d" . Chr(0xE9) . "j" . Chr(0xE0) . " vu" . Chr(0x202F) . "ab" . Chr(0x20AC) . "cdefghij"
	Prediction := "Bonjour, " . Chr(0xE7) . "a marche " . Chr(0xE0) . " merveille" . Chr(0x2019) . "s test."
	Pasted := "Coll" . Chr(0xE9) . " " . Chr(0x20AC) . "12 " . Chr(0x2014) . " texte de v" . Chr(0xE9) . "rification"
	Prefill := "xxxxx"
	Burst := "{Backspace 5}{Text}" . Replacement
	Scenarios := []
	Scenarios.Push(Map("id", "expansion", "spec", Map("prefill", Prefill, "expected", Replacement,
		"rival", "", "send", (Mode) => _IP_Send(Burst, Mode, true))))
	Scenarios.Push(Map("id", "paste", "spec", Map("prefill", "", "expected", Pasted,
		"rival", "", "send", (Mode) => _IP_Send("^v", Mode, true), "clipboard", Pasted)))
	Scenarios.Push(Map("id", "prediction", "spec", Map("prefill", "", "expected", Prediction,
		"rival", "", "send", (Mode) => _IP_SendThroughFunnel("{Text}" . Prediction, Mode))))
	Scenarios.Push(Map("id", "rival", "spec", Map("prefill", Prefill, "expected", Replacement,
		"rival", INPUT_PROBE_RIVAL_CHAR, "send", (Mode) => _IP_Send(Burst, Mode, false))))
	return Scenarios
}





; =============================================
; =============================================
; ======= 4/ Send comparison ==================
; =============================================
; =============================================

; Measures every scenario under both send primitives.
; Headless of dialogs: the menu command wraps it.
; @param Reps {Integer} Repetitions per scenario and primitive.
; @returns {Map} state = done | aborted, reason, rows, pass.
InputProbe_RunSendComparison(Reps := 0) {
	global _InputProbeBusy, INPUT_PROBE_TAG, INPUT_PROBE_REPS, INPUT_PROBE_MODES
	Result := Map("state", "aborted", "reason", "", "rows", [], "pass", false)
	if (Reps < 1)
		Reps := INPUT_PROBE_REPS
	Reason := _IP_Admission()
	if (Reason != "") {
		Result["reason"] := Reason
		try LoggerWarn(INPUT_PROBE_TAG, "Send comparison not run: {1}.", Reason)
		return Result
	}
	_InputProbeBusy := true
	Target := 0
	try {
		try LoggerStart(INPUT_PROBE_TAG, "Send comparison started ({1} repetition(s) per scenario).", Reps)
		Target := _IP_OpenTarget()
		if !Target {
			Result["reason"] := "foreground"
			try LoggerWarn(INPUT_PROBE_TAG, "Send comparison aborted: the check window could not take the focus.")
			return Result
		}
		Frequency := 0
		DllCall("QueryPerformanceFrequency", "Int64*", &Frequency)
		try LoggerEvidence(INPUT_PROBE_TAG, "send_compare context ahk={1} os={2} key_delay={3} send_level={4} reps={5}",
			A_AhkVersion, A_OSVersion, A_KeyDelay, A_SendLevel, Reps)
		for Scenario in _IP_Scenarios() {
			Spec := Scenario["spec"]
			Held := _IP_HoldClipboard(Spec)
			if (Held is String && Held == "skipped") {
				try LoggerEvidence(INPUT_PROBE_TAG, "send_compare scenario={1} skipped=clipboard_busy", Scenario["id"])
				continue
			}
			try {
				for Mode in INPUT_PROBE_MODES {
					Collected := []
					; One unmeasured warm-up repetition: the first send of a primitive
					; pays one-off costs that would hide its steady-state latency.
					_IP_RunRep(Target, Spec, Mode, Frequency)
					Loop Reps {
						Rep := _IP_RunRep(Target, Spec, Mode, Frequency)
						if (Rep["kind"] == "foreground") {
							Result["reason"] := "foreground"
							try LoggerWarn(INPUT_PROBE_TAG, "Send comparison aborted: the check window lost the focus.")
							return Result
						}
						Collected.Push(Rep)
					}
					Row := InputProbe_SummarizeRow(Scenario["id"], Mode, Collected)
					Result["rows"].Push(Row)
					try LoggerEvidence(INPUT_PROBE_TAG, "{1}", InputProbe_RowRecord(Row))
				}
			} finally
				_IP_ReleaseClipboard(Held)
		}
		Result["state"] := "done"
		Result["pass"] := true
		for Row in Result["rows"] {
			if !InputProbe_RowPasses(Row)
				Result["pass"] := false
		}
		try LoggerSuccess(INPUT_PROBE_TAG, "Send comparison finished (pass={1}).", Result["pass"] ? 1 : 0)
		return Result
	} finally {
		if IsObject(Target)
			Target["gui"].Destroy()
		_InputProbeBusy := false
	}
}

; Puts a scenario's clipboard payload in place under the clipboard owner.
; @param Spec {Map}
; @returns {Object|String} "" when the scenario needs no clipboard, "skipped"
;   when it cannot have it, else the held snapshot.
_IP_HoldClipboard(Spec) {
	if !Spec.Has("clipboard")
		return ""
	if (CB_IsBusy() || CB_HasImage())
		return "skipped"
	Token := CB_TryBeginPasteTransaction("input_probe")
	if !Token
		return "skipped"
	Saved := CB_SaveAll()
	if (Type(Saved) == "String" && Saved == "__CB_SAVE_ERROR__") {
		CB_EndOwnedTransaction(Token)
		return "skipped"
	}
	if !CB_Write(Spec["clipboard"]) {
		CB_RestoreOwnedAllEventually(Saved, 0, Token, "input_probe", true, true)
		return "skipped"
	}
	return Map("token", Token, "saved", Saved, "sequence", CB_GetSequenceNumber())
}

; Gives the clipboard back to the user.
; @param Held {Object|String} What _IP_HoldClipboard returned.
_IP_ReleaseClipboard(Held) {
	if !(Held is Map)
		return
	CB_RestoreOwnedAllEventually(Held["saved"], Held["sequence"], Held["token"], "input_probe")
}





; ===========================================
; ===========================================
; ======= 5/ Keyboard hook order ============
; ===========================================
; ===========================================

; Low-level keyboard hook of the test: counts the probe key, passes everything on.
_IP_HookProc(Code, WParam, LParam) {
	global _InputProbeHookSeen, INPUT_PROBE_HOOK_VK
	if (Code >= 0 && (WParam == 0x100 || WParam == 0x104)
			&& NumGet(LParam, 0, "UInt") == INPUT_PROBE_HOOK_VK)
		_InputProbeHookSeen += 1
	return DllCall("CallNextHookEx", "Ptr", 0, "Int", Code, "Ptr", WParam, "Ptr", LParam, "Ptr")
}

; The probe hotkey. It has no other effect: its job is to swallow the key.
_IP_HookHotkey(*) {
	global _InputProbeHookFired
	_InputProbeHookFired += 1
}

; Installs the test hook on this thread, the newest of the chain.
; @param Callback {Integer} CallbackCreate address.
; @returns {Integer} The hook handle.
_IP_HookInstall(Callback) {
	Hook := DllCall("SetWindowsHookExW", "Int", 13, "Ptr", Callback,
		"Ptr", DllCall("GetModuleHandleW", "Ptr", 0, "Ptr"), "UInt", 0, "Ptr")
	if !Hook
		throw OSError(A_LastError, "SetWindowsHookExW")
	return Hook
}

; Injects the probe key once and reports what each side saw.
; @param Mode {String} SendEvent | SendInput
; @returns {Map} seen, fired.
_IP_HookInject(Mode) {
	global _InputProbeHookSeen, _InputProbeHookFired
	global INPUT_PROBE_HOOK_KEYS, INPUT_PROBE_HOOK_WAIT_MS
	_InputProbeHookSeen := 0
	_InputProbeHookFired := 0
	PreviousLevel := A_SendLevel
	; Level 1 is above the probe hotkey's level 0, so the hotkey may fire on it.
	SendLevel(1)
	try {
		if (Mode == "SendInput")
			SendInput(INPUT_PROBE_HOOK_KEYS)
		else
			SendEvent(INPUT_PROBE_HOOK_KEYS)
	} finally
		SendLevel(PreviousLevel)
	Deadline := A_TickCount + INPUT_PROBE_HOOK_WAIT_MS
	while (_InputProbeHookFired < 1 && A_TickCount < Deadline)
		Sleep(10)
	; A key that AutoHotkey let through reaches the test hook within the same
	; send; the extra pause only lets a late callback land.
	Sleep(40)
	return Map("seen", _InputProbeHookSeen, "fired", _InputProbeHookFired)
}

; Records which hook runs first before and after a SendInput.
; @returns {Map} state = done | aborted, reason, verdict, record, pass.
InputProbe_RunHookOrder() {
	global _InputProbeBusy, INPUT_PROBE_TAG, INPUT_PROBE_HOOK_HOTKEY
	Result := Map("state", "aborted", "reason", "", "verdict", Map(), "record", "", "pass", false)
	Reason := _IP_Admission()
	if (Reason != "") {
		Result["reason"] := Reason
		try LoggerWarn(INPUT_PROBE_TAG, "Hook order check not run: {1}.", Reason)
		return Result
	}
	_InputProbeBusy := true
	Target := 0
	Callback := 0
	Hook := 0
	HotkeyOn := false
	try {
		try LoggerStart(INPUT_PROBE_TAG, "Hook order check started.")
		Target := _IP_OpenTarget()
		if !Target {
			Result["reason"] := "foreground"
			try LoggerWarn(INPUT_PROBE_TAG, "Hook order check aborted: the check window could not take the focus.")
			return Result
		}
		; A hotkey declared with no criterion, even when the driver was last
		; registering one under a #HotIf, so the probe key is judged by AutoHotkey's
		; hook for every window.
		HotIf()
		Hotkey(INPUT_PROBE_HOOK_HOTKEY, _IP_HookHotkey, "On I0")
		HotkeyOn := true
		Callback := CallbackCreate(_IP_HookProc, "Fast", 3)
		Hook := _IP_HookInstall(Callback)
		Before := _IP_HookInject("SendEvent")
		; Real SendInput: AutoHotkey removes its hook for the send and installs it
		; again, newest, afterwards. The hotkey cannot fire during it.
		During := _IP_HookInject("SendInput")
		After := _IP_HookInject("SendEvent")
		; Control: the test hook installed again is the newest and must run first,
		; or the whole method (suppression seen from a newer hook) is unsound.
		DllCall("UnhookWindowsHookEx", "Ptr", Hook)
		Hook := _IP_HookInstall(Callback)
		Control := _IP_HookInject("SendEvent")
		Verdict := InputProbe_HookVerdict(Before, During, After, Control)
		Result["verdict"] := Verdict
		Result["record"] := InputProbe_HookRecord(Before, During, After, Control, Verdict)
		try LoggerEvidence(INPUT_PROBE_TAG, "{1}", Result["record"])
		Result["state"] := "done"
		Result["pass"] := Verdict["conclusive"]
		try LoggerSuccess(INPUT_PROBE_TAG, "Hook order check finished (conclusive={1}).", Verdict["conclusive"] ? 1 : 0)
		return Result
	} finally {
		if Hook
			DllCall("UnhookWindowsHookEx", "Ptr", Hook)
		if Callback
			CallbackFree(Callback)
		if HotkeyOn {
			HotIf()
			Hotkey(INPUT_PROBE_HOOK_HOTKEY, "Off")
		}
		if IsObject(Target)
			Target["gui"].Destroy()
		_InputProbeBusy := false
	}
}





; ==========================================
; ==========================================
; ======= 6/ Menu commands =================
; ==========================================
; ==========================================

; Text of the dialog for a run that did not start.
; @param Reason {String} busy | paused | foreground | keys_held
; @returns {String}
_IP_AbortText(Reason) {
	return Format(t("input_probe.aborted"), t("input_probe.reason." . Reason))
}

; Milliseconds with one decimal.
; @param Micros {Integer}
; @returns {String}
_IP_Millis(Micros) {
	return Format("{:.1f}", Micros / 1000)
}

; Dialog text of a finished send comparison: one line per scenario and primitive.
; @param Result {Map}
; @returns {String}
InputProbe_SendComparisonText(Result) {
	Lines := t(Result["pass"] ? "input_probe.pass" : "input_probe.fail")
	for Row in Result["rows"] {
		Lines .= "`n" . Format(t("input_probe.send_line"), t("input_probe.scenario." . Row["scenario"]),
			Row["mode"], Row["exact"], Row["n"], Row["lost"], Row["interleaved"],
			_IP_Millis(Row["settle_med_us"]), _IP_Millis(Row["settle_max_us"]))
	}
	return Lines . "`n`n" . t("input_probe.evidence")
}

; Dialog text of a finished hook check.
; @param Result {Map}
; @returns {String}
InputProbe_HookOrderText(Result) {
	Verdict := Result["verdict"]
	Lines := t(Result["pass"] ? "input_probe.pass" : "input_probe.fail")
	Lines .= "`n" . Format(t("input_probe.hook_line"), t("input_probe.hook_phase_before"),
		t("input_probe.hook_" . Verdict["before"]))
	Lines .= "`n" . Format(t("input_probe.hook_line"), t("input_probe.hook_phase_after"),
		t("input_probe.hook_" . Verdict["after"]))
	if (Verdict["rehook"] == "no")
		Lines .= "`n" . t("input_probe.hook_rehook_no")
	else if (Verdict["changed"] != "unknown")
		Lines .= "`n" . t("input_probe.hook_changed_" . Verdict["changed"])
	return Lines . "`n`n" . t("input_probe.evidence")
}

; Debug menu: "Measure SendEvent vs SendInput".
InputProbe_SendComparisonCommand(*) {
	if (Ui_MsgBox(Format(t("input_probe.confirm"), 10), t("input_probe.title"), "YesNo Icon?") != "Yes")
		return
	Result := InputProbe_RunSendComparison()
	if (Result["state"] != "done") {
		Ui_MsgBox(_IP_AbortText(Result["reason"]), t("input_probe.title"), "Icon!")
		return
	}
	Ui_MsgBox(InputProbe_SendComparisonText(Result), t("input_probe.title"), Result["pass"] ? "Iconi" : "Icon!")
}

; Debug menu: "Record keyboard hook order".
InputProbe_HookOrderCommand(*) {
	if (Ui_MsgBox(Format(t("input_probe.confirm"), 5), t("input_probe.title"), "YesNo Icon?") != "Yes")
		return
	Result := InputProbe_RunHookOrder()
	if (Result["state"] != "done") {
		Ui_MsgBox(_IP_AbortText(Result["reason"]), t("input_probe.title"), "Icon!")
		return
	}
	Ui_MsgBox(InputProbe_HookOrderText(Result), t("input_probe.title"), Result["pass"] ? "Iconi" : "Icon!")
}
