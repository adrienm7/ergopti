; tests/unit/modules/llm/servers/test_ollama_failure_epoch_publication.ahk

#Requires AutoHotkey v2.0

; Observe the real logger and existing priority port. Scheduling uses a real
; timer and real dependency cancellation, never a fabricated epoch mutation.
class _OFEP_Fixture {
	__New(Mode) {
		this.Mode := Mode
		; The headless include graph omits the entry's process-priority seed.
		; Resolve its one canonical declaration before entering the state claim.
		Driver := _DriverSourceConcat()
		ActiveDriver := _DriverMaskBlockComments(&Driver)
		Pattern := 'm)^global DRIVER_BASELINE_PRIORITY_CLASS := "([^"`r`n]+)"$'
		Assert(RegExMatch(ActiveDriver, Pattern, &Baseline) > 0,
			"the fixture requires the real entry's process-priority declaration")
		Assert(!RegExMatch(ActiveDriver, Pattern, , Baseline.Pos + Baseline.Len),
			"only the unique production declaration may seed fixture priority")
		this.Baseline := Baseline[1]
		this.Prepared := false
		this.TimerFn := 0
		this.SinkFn := 0
		this.LogCalls := 0
		this.TimerCalls := 0
		this.PriorityCalls := 0
		this.FailureCalls := 0
		this.ObserverFailure := ""
		this.TimerFailure := ""
	}
	Setup() {
		global _LLM_Deps_State, _LLM_Deps_FailureMessage, _LLM_Deps_Checking, _LLM_Deps_Epoch
		global _LLM_Deps_InstallerOwner, _LLM_ManagedBootstrap, _LLM_Deps_PollTimer
		global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
		global DRIVER_BASELINE_PRIORITY_CLASS
		AssertFalse(IsObject(_LLM_Deps_InstallerOwner), "the fixture cannot cancel a foreign installer owner")
		AssertFalse(IsObject(_LLM_ManagedBootstrap), "the fixture cannot cancel a foreign managed bootstrap")
		AssertTrue(!IsSet(_LLM_Deps_PollTimer) || !_LLM_Deps_PollTimer, "the fixture cannot stop another poll timer")
		AssertEqual(0, _LOGGER_TEST_SINK, "the fixture cannot replace another active logger observer")
		this.LoggerState := _TLOG_CaptureLoggerState()
		AssertFalse(this.LoggerState.FlushActive, "the fixture cannot detach an active logger flush")
		this.Priority := DllCall("GetPriorityClass", "Ptr", DllCall("GetCurrentProcess", "Ptr"), "UInt")
		AssertTrue(this.Priority > 0, "native priority must be observed before the fixture changes state")
		this.Saved := Map("state", _LLM_Deps_State, "checking", _LLM_Deps_Checking, "epoch", _LLM_Deps_Epoch,
			"message_present", IsSet(_LLM_Deps_FailureMessage), "poll_present", IsSet(_LLM_Deps_PollTimer),
			"sink", _LOGGER_TEST_SINK, "repeat", _LOGGER_REPEAT_ENABLED,
			"baseline_present", IsSet(DRIVER_BASELINE_PRIORITY_CLASS),
			"installer", _LLM_Deps_InstallerOwner, "managed", _LLM_ManagedBootstrap)
		if this.Saved["baseline_present"]
			this.Saved["baseline"] := DRIVER_BASELINE_PRIORITY_CLASS
		if this.Saved["message_present"]
			this.Saved["message"] := _LLM_Deps_FailureMessage
		if this.Saved["poll_present"]
			this.Saved["poll"] := _LLM_Deps_PollTimer
		this.Prepared := true
		DRIVER_BASELINE_PRIORITY_CLASS := this.Baseline
		_ResetLogger()
		LOGGER_SUB_FILES := Map(), _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_REPEAT_ENABLED := false
		_LLM_Deps_State := "pending"
		_LLM_Deps_Checking := true
		_LLM_Deps_Epoch := 9201
		_LLM_Deps_FailureMessage := "new-epoch-message-unpublished"
		this.Epoch := _LLM_Deps_Epoch
		this.Message := "epoch publication fixture " . this.Mode . " " . A_ScriptHwnd
		this.TimerFn := ObjBindMethod(this, "CancelFromTimer")
		this.SinkFn := ObjBindMethod(this, "ObserveLog")
		LoggerSetTestSink(this.SinkFn)
	}
	ObserveLog(Line) {
		if !InStr(Line, "[LLM] Deps failure: " . this.Message)
			return
		this.LogCalls += 1
		try {
			if this.Mode == "logger"
				this.WaitForCancellation("pending")
		} catch as Err
			this.ObserverFailure := Err.Message
	}
	WaitForCancellation(ExpectedState) {
		global _LLM_Deps_State, _LLM_Deps_Epoch
		AssertFalse(A_IsCritical, "the real cancellation timer must run outside any publication claim")
		AssertEqual(this.Epoch, _LLM_Deps_Epoch)
		AssertEqual(ExpectedState, _LLM_Deps_State, "the scheduler boundary must reach its exact publication phase")
		Started := OllamaRuntime_Now()
		SetTimer(this.TimerFn, -1)
		while this.TimerCalls == 0 && OllamaRuntime_Now() - Started < 1000
			Sleep(10)
		AssertEqual(1, this.TimerCalls, "a real timer must cancel before the observed call returns")
		AssertEqual("", this.TimerFailure)
		AssertTrue(this.CancelResult, "real dependency cancellation must acknowledge only the empty owned ports")
		AssertEqual(this.Epoch + 1, _LLM_Deps_Epoch, "the real cancel API must revoke the captured epoch")
	}
	CancelFromTimer() {
		global _LLM_Deps_State, _LLM_Deps_FailureMessage, _LLM_Deps_Epoch
		global _LLM_Deps_InstallerOwner, _LLM_ManagedBootstrap, _LLM_Deps_PollTimer
		this.TimerCalls += 1
		try {
			AssertFalse(IsObject(_LLM_Deps_InstallerOwner) || IsObject(_LLM_ManagedBootstrap),
				"the cancellation observer must never retire another fixture's owner")
			AssertTrue(!IsSet(_LLM_Deps_PollTimer) || !_LLM_Deps_PollTimer)
			this.CancelResult := LLM_Deps_Cancel()
			this.CancelState := _LLM_Deps_State
			this.CancelMessage := _LLM_Deps_FailureMessage
			this.CancelEpoch := _LLM_Deps_Epoch
			this.PriorityAfterCancel := DllCall("GetPriorityClass", "Ptr", DllCall("GetCurrentProcess", "Ptr"), "UInt")
		} catch as Err
			this.TimerFailure := Err.Message
	}
	PriorityObserver(Priority) {
		global _LLM_Deps_Epoch
		this.PriorityCalls += 1
		this.PriorityEpoch := _LLM_Deps_Epoch
		try {
			AssertFalse(A_IsCritical, "the priority port must remain outside the state claim")
			AssertEqual(this.Baseline, Priority, "the real publication must pass its canonical baseline to the observer")
			ProcessSetPriority(Priority)
			if this.Mode == "priority"
				this.WaitForCancellation("failed")
		} catch as Err {
			this.ObserverFailure := Err.Message
			throw Err
		}
	}
	FailureObserver(Message) {
		global _LLM_Deps_State, _LLM_Deps_Epoch
		this.FailureCalls += 1
		this.FailureEpoch := _LLM_Deps_Epoch
		AssertFalse(A_IsCritical, "business callbacks must stay outside the state claim")
		AssertEqual(this.Message, Message)
		AssertEqual("failed", _LLM_Deps_State)
	}
	Close() {
		global _LLM_Deps_State, _LLM_Deps_FailureMessage, _LLM_Deps_Checking, _LLM_Deps_Epoch, _LLM_Deps_PollTimer
		global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, DRIVER_BASELINE_PRIORITY_CLASS
		if HasMethod(this.TimerFn, "Call")
			SetTimer(this.TimerFn, 0)
		if !this.Prepared
			return
		try {
			_LOGGER_TEST_SINK := this.Saved["sink"]
			_LOGGER_REPEAT_ENABLED := this.Saved["repeat"]
			_TLOG_RestoreLoggerState(this.LoggerState)
			_LLM_Deps_State := this.Saved["state"]
			_LLM_Deps_Checking := this.Saved["checking"]
			_LLM_Deps_Epoch := this.Saved["epoch"]
			if this.Saved["message_present"]
				_LLM_Deps_FailureMessage := this.Saved["message"]
			else
				_LLM_Deps_FailureMessage := unset
			if this.Saved["poll_present"]
				_LLM_Deps_PollTimer := this.Saved["poll"]
			else
				_LLM_Deps_PollTimer := unset
		} finally {
			if this.Saved["baseline_present"]
				DRIVER_BASELINE_PRIORITY_CLASS := this.Saved["baseline"]
			else
				DRIVER_BASELINE_PRIORITY_CLASS := unset
			Restored := DllCall("SetPriorityClass", "Ptr", DllCall("GetCurrentProcess", "Ptr"), "UInt", this.Priority, "Int")
			this.TimerFn := 0
			this.SinkFn := 0
			AssertTrue(Restored, "the fixture must restore its original native priority")
			AssertEqual(this.Saved["baseline_present"], IsSet(DRIVER_BASELINE_PRIORITY_CLASS),
				"the fixture must preserve the entry seed's assigned or unset lifetime")
			if this.Saved["baseline_present"]
				AssertEqual(this.Saved["baseline"], DRIVER_BASELINE_PRIORITY_CLASS,
					"the fixture must restore the exact previous priority declaration")
		}
	}
}

_OFEP_Case(Mode) {
	global _LLM_Deps_State, _LLM_Deps_FailureMessage, _LLM_Deps_Checking, _LLM_Deps_Epoch
	global _LLM_Deps_InstallerOwner, _LLM_ManagedBootstrap
	F := _OFEP_Fixture(Mode)
	PreviousCritical := Critical("On")
	try {
		F.Setup()
		Captured := Mode == "stale" ? F.Epoch - 1 : Mode == "legacy" ? 0 : F.Epoch
		Critical("Off")
		Result := _LLM_Deps_PublishFailure(F.Message, ObjBindMethod(F, "FailureObserver"), Captured,
			ObjBindMethod(F, "PriorityObserver"))
		AssertEqual("", F.ObserverFailure, "the real logger/priority observer must not hide assertion failures")
		AssertEqual("", F.TimerFailure)
		if Mode == "logger" || Mode == "priority" {
			AssertFalse(Result, "the revoked captured epoch cannot finish failure delivery")
			AssertEqual(1, F.LogCalls)
			AssertEqual(1, F.TimerCalls)
			AssertEqual(F.Epoch + 1, _LLM_Deps_Epoch)
			AssertEqual("pending", F.CancelState)
			AssertEqual(F.CancelState, _LLM_Deps_State, "stale publication cannot overwrite real cancellation")
			AssertEqual(F.CancelMessage, _LLM_Deps_FailureMessage)
			AssertFalse(_LLM_Deps_Checking)
			AssertEqual(0, F.FailureCalls, "an old failure callback cannot touch the cancelled/new epoch")
			AssertEqual(Mode == "priority" ? 1 : 0, F.PriorityCalls)
			AssertEqual(F.PriorityAfterCancel, DllCall("GetPriorityClass", "Ptr", DllCall("GetCurrentProcess", "Ptr"), "UInt"))
		} else if Mode == "stale" {
			AssertFalse(Result)
			AssertEqual(0, F.LogCalls + F.TimerCalls + F.PriorityCalls + F.FailureCalls)
			AssertEqual("pending", _LLM_Deps_State)
			AssertTrue(_LLM_Deps_Checking)
			AssertEqual("new-epoch-message-unpublished", _LLM_Deps_FailureMessage)
		} else {
			AssertTrue(Result, "a current failure must still publish normally")
			AssertEqual(1, F.LogCalls)
			AssertEqual(0, F.TimerCalls)
			AssertEqual(1, F.PriorityCalls)
			AssertEqual(1, F.FailureCalls)
			AssertEqual(F.Epoch, F.PriorityEpoch)
			AssertEqual(F.Epoch, F.FailureEpoch)
			AssertEqual("failed", _LLM_Deps_State)
			AssertEqual(F.Message, _LLM_Deps_FailureMessage)
			AssertFalse(_LLM_Deps_Checking)
		}
		AssertEqual(F.Saved["installer"], _LLM_Deps_InstallerOwner)
		AssertEqual(F.Saved["managed"], _LLM_ManagedBootstrap)
	} finally {
		try F.Close()
		finally Critical(PreviousCritical)
	}
}
Test("Ollama failure epoch: real logger cancellation refuses global publication (failure-epoch-publication)", _OFEP_Case.Bind("logger"))
Test("Ollama failure epoch: priority cancellation refuses the stale callback (failure-epoch-publication)", _OFEP_Case.Bind("priority"))
Test("Ollama failure epoch: current failure delivers once (failure-epoch-publication)", _OFEP_Case.Bind("current"))
Test("Ollama failure epoch: initially stale failure has no effects (failure-epoch-publication)", _OFEP_Case.Bind("stale"))
Test("Ollama failure epoch: zero epoch retains legacy current delivery (failure-epoch-publication)", _OFEP_Case.Bind("legacy"))
