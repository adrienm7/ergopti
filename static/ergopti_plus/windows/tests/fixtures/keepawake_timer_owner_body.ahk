; tests/fixtures/keepawake_timer_owner_body.ahk

; Native session hooks and Start/Stop are real. Only the two position samples
; and all subject timer calls are bound with consistent callback identity. Delivery is a real SetTimer,
; with controlled coordinates and no physical mouse displacement.
global _KATO := {Mode: A_Args[1], X: 100, Y: 200, Samples: 0, Timers: Map(), Hooks: [],
	Capturing: false, Subject: 0, SubjectArms: 0, Failure: 0, A: 0, B: 0, Logs: []}
global ActivitySimulation := false

_KATO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_KATO_Log(Line) {
	global _KATO
	if _KATO.Logs.Length < 32
		_KATO.Logs.Push(Line)
}

_KATO_MouseGetPos(&X, &Y) {
	global _KATO
	_KATO.Samples += 1
	X := _KATO.X, Y := _KATO.Y
}

_KATO_Timer(Callback, Period, Priority := unset) {
	global _KATO
	_KATO_Require(HasMethod(Callback, "Call"), "every subject timer must retain a callable canonical identity")
	if !_KATO.Timers.Has(Callback) {
		if Period == 0 {
			; Preserve a native no-op cancellation of a never-armed callback.
			if IsSet(Priority)
				SetTimer(Callback, Period, Priority)
			else
				SetTimer(Callback, Period)
			return
		}
		Record := {Callback: Callback, Timer: 0, Arms: 0, Cancelled: 0,
			Deliveries: 0, Settled: 0, Period: Period, Pending: false}
		Record.Timer := _KATO_Deliver.Bind(Record)
		_KATO.Timers[Callback] := Record
	}
	Record := _KATO.Timers[Callback]
	if _KATO.Capturing {
		_KATO_Require(A_IsCritical && Period == -1, "the genuine movement predicate must arm its deferred cancellation")
		_KATO_Require(!IsObject(_KATO.Subject), "the movement predicate may arm one originating callback")
		_KATO.Subject := Record, _KATO.SubjectArms += 1
	}
	if Period == 0 {
		if IsSet(Priority)
			SetTimer(Record.Timer, Period, Priority)
		else
			SetTimer(Record.Timer, Period)
		Record.Cancelled += 1, Record.Pending := false
	} else {
		Record.Arms += 1, Record.Period := Period, Record.Pending := true
		if IsSet(Priority)
			SetTimer(Record.Timer, Period, Priority)
		else
			SetTimer(Record.Timer, Period)
	}
}

_KATO_Deliver(Record) {
	global _KATO
	Record.Deliveries += 1
	if Record.Period < 0
		Record.Pending := false
	try {
		_KATO_Require(!A_IsCritical, "the native timer must run after the acquisition barrier releases")
		Record.Callback.Call()
	} catch Any as Failure {
		_KATO.Failure := Failure
	} finally Record.Settled += 1
}

_KATO_DisarmBackground() {
	; Start genuinely armed these timers. Retire them before releasing Critical
	; so the isolated model never jitters the physical desktop pointer.
	_KATO_Timer(SimulateActivity, 0)
	_KATO_Timer(AwakeCheckMouseMoved, 0)
	_KATO_Timer(AwakeReturnToOrigin, 0)
}

_KATO_Start() {
	global _KATO, AwakeInputHook, ActivitySimulation
	_KATO_Observe("before-native-start")
	_KATO_Require(StartActivitySimulation(), "the actual session Start must succeed before any ownership assertion")
	Hook := AwakeInputHook
	_KATO_Require(ActivitySimulation && Hook is InputHook && Hook.InProgress,
		"the session must publish and start its genuine native observer")
	_KATO.Hooks.Push(Hook)
	_KATO_DisarmBackground()
	return Hook
}

_KATO_Observe(Phase) {
	global _KATO, AwakeInputHook, ActivitySimulation
	FileAppend("OBSERVATION " . KL_JsonEncode(Map("phase", Phase, "mode", _KATO.Mode,
		"active", ActivitySimulation, "current", IsObject(AwakeInputHook) ? ObjPtr(AwakeInputHook) : 0,
		"a", IsObject(_KATO.A) ? ObjPtr(_KATO.A) : 0, "b", IsObject(_KATO.B) ? ObjPtr(_KATO.B) : 0,
		"b_running", IsObject(_KATO.B) ? _KATO.B.InProgress : 0, "arms", _KATO.SubjectArms,
		"deliveries", IsObject(_KATO.Subject) ? _KATO.Subject.Deliveries : 0,
		"settled", IsObject(_KATO.Subject) ? _KATO.Subject.Settled : 0,
		"cancelled", IsObject(_KATO.Subject) ? _KATO.Subject.Cancelled : 0, "samples", _KATO.Samples,
		"critical", A_IsCritical, "suspended", A_IsSuspended)) . "`n", "*")
}

_KATO_Exercise() {
	global _KATO, AwakeInputHook, ActivitySimulation, AWAKE_JITTER_PX
	Started := A_TickCount
	_KATO.A := _KATO_Start()
	_KATO.X += AWAKE_JITTER_PX + 1
	_KATO.Capturing := true
	try AwakeCheckMouseMoved()
	finally _KATO.Capturing := false
	_KATO_Require(_KATO.SubjectArms == 1 && _KATO.Samples == 2,
		"the real displacement predicate must arm one exact cancellation after two real callsites sampled")
	_KATO_Require(_KATO.Subject.Deliveries == 0, "the native deferred timer must still be retained by Critical")
	if _KATO.Mode == "retired-session" {
		_KATO_Require(StopActivitySimulation(false), "A must actually stop before successor admission")
		_KATO_Require(!_KATO.A.InProgress && !IsObject(AwakeInputHook), "the native A observer must be retired")
		_KATO.B := _KATO_Start()
		_KATO_Require(_KATO.B != _KATO.A && AwakeInputHook == _KATO.B && _KATO.B.InProgress,
			"B must be a distinct admitted real session before the old timer resumes")
	} else {
		_KATO_Require(_KATO.Mode == "current-session", "the child mode must be exact")
		_KATO.B := _KATO.A
	}
	_KATO_Require(TickElapsed(Started) < 5000, "native Start must settle within the acquisition prerequisite bound")
	_KATO_Observe("before-release")
	Critical("Off")
	Started := A_TickCount
	while !_KATO.Subject.Settled && !_KATO.Subject.Cancelled && TickElapsed(Started) < 3000
		Sleep(10)
	if IsObject(_KATO.Failure)
		throw _KATO.Failure
	Delivered := _KATO.Subject.Deliveries == 1 && _KATO.Subject.Settled == 1
	Cancelled := _KATO.Subject.Cancelled > 0 && _KATO.Subject.Deliveries == 0 && !_KATO.Subject.Pending
	_KATO_Require(Delivered || Cancelled,
		"the originating callback must really settle or receive native cancellation through its exact mapping")
	_KATO_Observe("after-delivery")
	if _KATO.Mode == "retired-session" {
		_KATO_Require(ActivitySimulation && AwakeInputHook == _KATO.B && _KATO.B.InProgress,
			"the retired session's deferred cancellation must preserve the exact active successor B")
	} else {
		_KATO_Require(Delivered, "the current positive must really deliver its canonical callback")
		_KATO_Require(!ActivitySimulation && !IsObject(AwakeInputHook) && !_KATO.A.InProgress,
			"the current session's genuine timer must really stop its native observer")
	}
}

_KATO_Main() {
	global _KATO, _KATO_ActualOwnerHash, _I18nCache, _I18nCacheLoaded
	global _I18nFallbacksWarmed, _ALTGR_KANA_FIXUP
	_KATO_Require(A_Args.Length == 4 && A_Args[2] == _KATO_ActualOwnerHash, "the child ABI and actual production owner must match")
	_KATO_Require(CryptoSha256Bytes(FileRead(A_ScriptFullPath, "RAW")) == A_Args[3], "the child source must match the parent's physical bytes")
	_KATO_Require(CryptoSha256Bytes(FileRead(A_AhkPath, "RAW")) == A_Args[4], "the actual native runtime must match")
	_I18nCache := Map("keepawake.started", "Started", "keepawake.stopped", "Stopped", "keepawake.title", "Private test")
	_I18nCacheLoaded := true, _I18nFallbacksWarmed := true, _ALTGR_KANA_FIXUP := false
	SavedCritical := Critical("On"), SavedSuspend := A_IsSuspended
	Primary := 0, Cleanup := 0, DiagnosticFailure := 0
	LoggerSetTestSink(_KATO_Log)
	try {
		Suspend(false)
		_KATO_Exercise()
	} catch Any as Failure {
		Primary := Failure
		try _KATO_Observe("failure-before-cleanup")
		catch Any as ObservationError
			DiagnosticFailure := ObservationError
	} finally {
		Critical("On")
		try {
			for Callback, Record in _KATO.Timers {
				SetTimer(Record.Timer, 0)
				Record.Pending := false
				_KATO_Require(Record.Deliveries == Record.Settled, "every entered timer callback must settle before private cleanup")
			}
			_KATO_DisarmBackground()
			_KATO_Require(StopActivitySimulation(false), "the exact current cancellation observer must acknowledge cleanup")
			for Hook in _KATO.Hooks {
				Hook.Stop()
				_KATO_Require(!Hook.InProgress, "every actual native InputHook must retire before the receipt")
			}
			TrayTip()
		} catch Any as Failure {
			Cleanup := Failure
		} finally {
			for Callback, Record in _KATO.Timers
				Record.Callback := 0, Record.Timer := 0
			_KATO.Timers := Map(), _KATO.Hooks := [], _KATO.A := 0, _KATO.B := 0
			LoggerClearTestSink()
			Suspend(SavedSuspend)
			Critical(SavedCritical)
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(Cleanup)
		throw Cleanup
	if IsObject(DiagnosticFailure)
		throw DiagnosticFailure
	FileAppend("RECEIPT " . KL_JsonEncode(Map("pid", DllCall("GetCurrentProcessId", "UInt"), "mode", _KATO.Mode,
		"source_sha256", A_Args[3], "runtime_sha256", A_Args[4], "owner_sha256", _KATO_ActualOwnerHash,
		"subject_arms", _KATO.SubjectArms, "timer_deliveries", _KATO.Subject.Deliveries,
		"timer_settled", _KATO.Subject.Settled, "timer_cancelled", _KATO.Subject.Cancelled,
		"hooks_retired", 1, "mouse_injected", 0, "suspended", A_IsSuspended)) . "`n", "*")
}

try {
	_KATO_Main()
	ExitApp(0)
} catch Any as Failure {
	FileAppend("FAIL " . Failure.Message . "`n" . Failure.Stack, "**")
	ExitApp(1)
}
