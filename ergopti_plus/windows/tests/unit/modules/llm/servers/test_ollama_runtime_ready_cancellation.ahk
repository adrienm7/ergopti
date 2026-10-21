; tests/unit/modules/llm/servers/test_ollama_runtime_ready_cancellation.ahk

#Requires AutoHotkey v2.0

; The clock port creates an observable scheduler boundary, while every time
; receipt still comes from the real monotonic clock. Default Now does not pump.
class _ORRC_Fixture {
	__New(Phase) {
		this.Runtime := _ORT_Fixture()
		this.SavedOptions := this.Runtime.Owner.Options.Clone()
		this.Bootstrap := _G4B_Fixture()
		this.Bootstrap.Now := OllamaRuntime_Now()
		this.Bootstrap.Runtime := this.Runtime.Owner
		this.Phase := Phase
		this.ClockCalls := 0
		this.TimerCalls := 0
		this.TimerResult := false
		this.TimerFailure := ""
		this.TimerRecordRetired := false
		this.CancelTimer := ObjBindMethod(this, "Cancel")
		this.Runtime.Owner.Options["clock"] := ObjBindMethod(this, "Clock")
		this.Runtime.Owner.Options["read_ready"] := ObjBindMethod(this, "Read")
		this.Runtime.Owner.Options["live_identity"] := (*) => true
	}
	Start() {
		this.Bootstrap.Start()
		SetTimer(this.Bootstrap.Flow.Timer, 0)
		this.Record := this.Runtime.Owner.Record
		AssertTrue(this.Record is Map && this.Record["accepted"], "the actual bootstrap must admit its exact runtime task")
		this.Callback := this.Record["on_ready"]
		this.Target := this.Record["target"].Clone()
		this.Receipt := this.Read(this.Target)["receipt"]
	}
	Read(Target) {
		Receipt := this.Runtime.Receipt.Clone()
		for Name in ["runtime_ticket", "ticket", "root_identity", "version_identity", "manifest_sha256", "origin"]
			Receipt[Name] := Target[Name]
		return Map("receipt", Receipt, "image_sha256", "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc")
	}
	Clock() {
		this.ClockCalls += 1
		if this.Phase > 0 && this.ClockCalls == this.Phase {
			AssertFalse(A_IsCritical, "the scheduler boundary must allow the real cancellation timer")
			AssertEqual(this.Phase == 3, this.Record["ready"], "the timer reaches the selected actual readiness boundary")
			Started := OllamaRuntime_Now()
			SetTimer(this.CancelTimer, -1)
			while this.TimerCalls == 0 && OllamaRuntime_Now() - Started < 1000
				Sleep(10)
			AssertEqual(1, this.TimerCalls, "the real one-shot timer must run before the clock returns")
		}
		return OllamaRuntime_Now()
	}
	Cancel() {
		this.TimerCalls += 1
		try {
			this.TimerResult := this.Bootstrap.Flow.Cancel()
			this.TimerRecordRetired := !(this.Runtime.Owner.Record is Map)
		} catch as Err {
			this.TimerFailure := Err.Message
		}
	}
	Close() {
		SetTimer(this.CancelTimer, 0)
		try {
			this.Bootstrap.Close()
			AssertFalse(this.Runtime.Owner.HasOwner(), "the fixture must release its exact runtime owner")
		} finally {
			; Remove this observer's own BoundFunc references even on failure.
			this.Runtime.Owner.Options := this.SavedOptions
			this.SavedOptions := 0
			this.CancelTimer := 0
		}
	}
}

_ORRC_TimerCancellation(Phase) {
	PreviousCritical := Critical("On")
	F := _ORRC_Fixture(Phase)
	try {
		F.Start()
		Critical("Off")
		Failure := "", Result := "unreturned"
		try Result := F.Runtime.Owner.ObserveReady()
		catch as Err
			Failure := Err.Message
		AssertEqual("", F.TimerFailure, "the real cancellation callback must complete normally")
		AssertEqual(1, F.TimerCalls, "the cancellation must occur in a real timer thread")
		AssertTrue(F.TimerResult && F.TimerRecordRetired, "strict physical retirement precedes readiness continuation")
		AssertEqual("", Failure, "retirement during the clock must not dereference a retired task or record")
		AssertFalse(Result, "cancelled readiness must be refused after the scheduler boundary")
		AssertTrue(F.Bootstrap.Flow.Cancelled)
		AssertFalse(F.Bootstrap.Flow.ServerReady, "cancelled readiness cannot publish server metadata")
		AssertFalse(F.Bootstrap.Flow.Ready)
		AssertEqual(0, F.Bootstrap.ReadyCalls, "the actual bootstrap success callback must remain silent")
		AssertEqual(1, F.Runtime.Stops, "only the exact admitted runtime task is retired")
		AssertEqual(1, F.Runtime.RetireCalls, "the physical file retirement observer completes once")
	} finally {
		try F.Close()
		finally Critical(PreviousCritical)
	}
}
Test("Ollama runtime: timer cancellation before process identity refuses readiness (runtime-ready-delivery-owner)",
	_ORRC_TimerCancellation.Bind(2))
Test("Ollama runtime: timer cancellation before bootstrap delivery refuses readiness (runtime-ready-delivery-owner)",
	_ORRC_TimerCancellation.Bind(3))

_ORRC_ReadyControl() {
	PreviousCritical := Critical("On")
	F := _ORRC_Fixture(0)
	try {
		F.Start()
		Critical("Off")
		AssertTrue(F.Runtime.Owner.ObserveReady(), "the actual owner must deliver an uninterrupted ready receipt")
		SetTimer(F.Bootstrap.Flow.Timer, 0)
		AssertEqual(3, F.ClockCalls, "all three real monotonic observations complete")
		AssertTrue(F.Bootstrap.Flow.ServerReady && F.Bootstrap.Flow.Ready)
		AssertEqual(1, F.Bootstrap.ReadyCalls, "the actual bootstrap publishes successful readiness once")
		AssertFalse(F.Runtime.Owner.ObserveReady(), "the original ready callback cannot be replayed")
		AssertEqual(1, F.Bootstrap.ReadyCalls)
		AssertEqual(0, F.TimerCalls)
		AssertEqual(0, F.Runtime.Stops, "successful delivery keeps its admitted server alive")
	} finally {
		try F.Close()
		finally Critical(PreviousCritical)
	}
}
Test("Ollama runtime: uninterrupted bootstrap readiness is delivered once (runtime-ready-delivery-owner)", _ORRC_ReadyControl)

_ORRC_RetiredBootstrapCallback() {
	PreviousCritical := Critical("On")
	F := _ORRC_Fixture(0)
	try {
		F.Start()
		Critical("Off")
		AssertTrue(F.Bootstrap.Flow.Cancel(), "the real bootstrap must retire its exact runtime owner")
		AssertFalse(F.Runtime.Owner.HasOwner())
		Failure := ""
		try F.Callback.Call(F.Target.Clone(), F.Receipt.Clone())
		catch as Err
			Failure := Err.Message
		AssertEqual("", Failure, "a retained real bootstrap callback cannot dereference a retired runtime record")
		AssertFalse(F.Bootstrap.Flow.ServerReady, "a retired callback cannot publish server metadata")
		AssertFalse(F.Bootstrap.Flow.Ready)
		AssertEqual(0, F.Bootstrap.ReadyCalls)
		AssertEqual(1, F.Runtime.Stops)
	} finally {
		try F.Close()
		finally Critical(PreviousCritical)
	}
}
Test("Ollama runtime: retained bootstrap callback refuses a retired runtime (runtime-ready-delivery-owner)",
	_ORRC_RetiredBootstrapCallback)
