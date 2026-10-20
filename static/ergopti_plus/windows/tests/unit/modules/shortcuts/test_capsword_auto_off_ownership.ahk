; tests/unit/modules/shortcuts/test_capsword_auto_off_ownership.ahk

; An older dispatcher snapshot or an ending callback can survive a user's
; off/on. Model that exact activation contract without touching the CapsLock
; LED: listeners, dispatcher, logger delivery and timers remain the real ones.

_CWAOO_Policy(Idle, Middle := false) {
	Pointer := Map()
	for Kind in CapsWordAutoOffPointerKinds()
		Pointer[Kind] := Kind == "middle_click" && Middle ? 1 : 0
	return CapsWordAutoOffCompile(Map("idle_timeout_seconds", Idle,
		"terminators", ["tab"], "pointer", Pointer), CapsWordAutoOffPointerKinds(), &Reason)
}

_CWAOO_End(State, Owner, Reason, Kind) {
	global CapsWordEnabled
	State.Ends.Push(Owner)
	CapsWordEnabled := false
}

_CWAOO_Rearm(State) {
	global CapsWordEnabled
	try {
		; The same order as ToggleCapsWord off then on; the LED is not emitted.
		CapsWordEnabled := false
		CapsWordAutoOffDisarm()
		CapsWordEnabled := true
		CapsWordAutoOff.Configured := State.NewPolicy
		CapsWordAutoOffArm(_CWAOO_End.Bind(State, "replacement"))
		State.Rearmed := true
	} catch as Err
		State.Error := Err
}

_CWAOO_PauseForRearm(State) {
	State.Pauses += 1
	if State.Pauses != 1
		return
	SetTimer(State.Timer, -1)
	Started := A_TickCount
	while !State.Rearmed && !IsObject(State.Error) && A_TickCount - Started < 2000
		Sleep(1)
	if !State.Rearmed && !IsObject(State.Error)
		State.Error := Error("The real replacement timer did not run during the retained callback.")
}

_CWAOO_Log(State, Line) {
	if InStr(Line, "[CapsWord] CapsWord switched off automatically (")
		_CWAOO_PauseForRearm(State)
}

_CWAOO_Peer(State, *) {
	_CWAOO_PauseForRearm(State)
}

_CWAOO_Case(Route) {
	global CapsWordEnabled, _LOGGER_TEST_SINK, _LOGGER_INFO_ENABLED, _LOGGER_DEBUG_ENABLED
	global _LOGGER_REPEAT_ENABLED, _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT, _LastErrTime
	AssertFalse(CapsWordAutoOff.Armed is Map, "the fixture must not borrow an active CapsWord")
	Saved := {Enabled: CapsWordEnabled, Configured: CapsWordAutoOff.Configured,
		Subscribers: HookDispatcher._subscribers, Sink: _LOGGER_TEST_SINK,
		Info: _LOGGER_INFO_ENABLED, Debug: _LOGGER_DEBUG_ENABLED,
		Repeat: _LOGGER_REPEAT_ENABLED, Dedup: _LOGGER_DEDUP_KEY,
		DedupLevel: _LOGGER_DEDUP_LEVEL, DedupCount: _LOGGER_DEDUP_COUNT, DedupAt: _LastErrTime,
		Critical: A_IsCritical, Suspended: A_IsSuspended}
	State := {Ends: [], Rearmed: false, Pauses: 0, Error: 0,
		NewPolicy: _CWAOO_Policy(30)}
	State.Timer := _CWAOO_Rearm.Bind(State)
	Peer := _CWAOO_Peer.Bind(State)
	try {
		Critical("Off"), Suspend(false)
		HookDispatcher._subscribers := Map()
		_LOGGER_INFO_ENABLED := true, _LOGGER_DEBUG_ENABLED := false
		_LOGGER_REPEAT_ENABLED := false, _LOGGER_DEDUP_KEY := ""
		LoggerSetTestSink(Route == "snapshot" ? 0 : _CWAOO_Log.Bind(State))
		if Route == "snapshot"
			HookDispatcher.Register(HookDispatcherConst.EVT_MS_MDOWN, Peer)
		CapsWordEnabled := true
		CapsWordAutoOff.Configured := _CWAOO_Policy(Route == "idle" ? 0.05 : 0, true)
		CapsWordAutoOffArm(_CWAOO_End.Bind(State, "original"))
		if Route == "snapshot" || Route == "pointer-log"
			HookDispatcher.Dispatch(HookDispatcherConst.EVT_MS_MDOWN)
		else if Route == "char-log"
			HookDispatcher.Dispatch(HookDispatcherConst.EVT_KB_CHAR, 0, "`t")
		else if Route == "idle" {
			Started := A_TickCount
			while State.Pauses == 0 && A_TickCount - Started < 2000
				Sleep(1)
		} else
			throw ValueError("Unknown CapsWord ownership fixture route.")
		if IsObject(State.Error)
			throw State.Error
		AssertEqual(1, State.Pauses, "the original dispatch or ending log must reach its real interruption boundary")
		AssertTrue(State.Rearmed, "a native timer must have actually armed the replacement")
		AssertTrue(CapsWordEnabled, "the retired callback must leave the replacement active")
		AssertTrue(CapsWordAutoOff.Armed == State.NewPolicy, "the exact newly armed policy must remain owned")
		AssertEqual(0, State.Ends.Length, "an original event must not invoke its retired end function or the replacement's")
		AssertTrue(CapsWordAutoOff.IdleRunning, "the replacement keeps its own idle timer")
		; A fresh event must still end the replacement normally.
		HookDispatcher.Dispatch(HookDispatcherConst.EVT_KB_CHAR, 0, "`t")
		AssertFalse(CapsWordEnabled)
		AssertEqual(1, State.Ends.Length)
		AssertEqual("replacement", State.Ends[1])
	} finally {
		SetTimer(State.Timer, 0)
		State.Timer := 0
		LoggerSetTestSink(Saved.Sink)
		CapsWordAutoOffDisarm()
		HookDispatcher._subscribers := Saved.Subscribers
		CapsWordEnabled := Saved.Enabled, CapsWordAutoOff.Configured := Saved.Configured
		_LOGGER_INFO_ENABLED := Saved.Info, _LOGGER_DEBUG_ENABLED := Saved.Debug
		_LOGGER_REPEAT_ENABLED := Saved.Repeat, _LOGGER_DEDUP_KEY := Saved.Dedup
		_LOGGER_DEDUP_LEVEL := Saved.DedupLevel, _LOGGER_DEDUP_COUNT := Saved.DedupCount, _LastErrTime := Saved.DedupAt
		Suspend(Saved.Suspended), Critical(Saved.Critical)
	}
}

for _CWAOO_Route in ["snapshot", "pointer-log", "char-log", "idle"]
	Test("CapsWord ownership: " . _CWAOO_Route . " cannot retire a replacement activation (capsword-auto-off-owner)",
		_CWAOO_Case.Bind(_CWAOO_Route))
