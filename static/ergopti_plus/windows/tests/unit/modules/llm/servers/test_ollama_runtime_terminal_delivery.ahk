; tests/unit/modules/llm/servers/test_ollama_runtime_terminal_delivery.ahk

#Requires AutoHotkey v2.0

; This adapter keeps the real runtime owner and its real bootstrap callback.
; Only delivery scheduling is observed: the task is already canonically terminal.
class _ORTD_Runtime {
	__New(Fixture) {
		this.Fixture := Fixture
	}
	Record {
		get => this.Fixture.Runtime.Owner.Record
	}
	Start(Target, Authority, Ready, Exit) {
		this.Callback := Exit
		return this.Fixture.Runtime.Owner.Start(Target, Authority, Ready, ObjBindMethod(this, "Deliver"))
	}
	Stop() => this.Fixture.Runtime.Owner.Stop()
	HasOwner() => this.Fixture.Runtime.Owner.HasOwner()
	Deliver(Code, Target) {
		F := this.Fixture
		F.Deliveries += 1
		F.TerminalRecord := this.Record
		AssertTrue(F.TerminalRecord["terminal"], "the real terminal owner precedes business delivery")
		AssertEqual(0, F.TerminalRecord["task"], "quiescent terminal delivery owns no live task")
		AssertFalse(F.Runtime.Owner._Current(F.TerminalRecord), "normal runtime currentness is false at every real exit")
		if F.Mode != "current" {
			AssertFalse(A_IsCritical, "delivery cancellation must be a real scheduler boundary")
			Started := OllamaRuntime_Now()
			SetTimer(F.CancelTimer, -1)
			while F.TimerCalls == 0 && OllamaRuntime_Now() - Started < 1000
				Sleep(10)
			AssertEqual(1, F.TimerCalls, "the real timer must revoke admission before delivery continues")
		}
		this.Callback.Call(Code, Target)
	}
}

class _ORTD_Fixture {
	__New(Mode) {
		global _LLM_Deps_FailureMessage
		this.HadMessage := IsSet(_LLM_Deps_FailureMessage)
		if this.HadMessage
			this.SavedMessage := _LLM_Deps_FailureMessage
		this.Priority := DllCall("GetPriorityClass", "Ptr", DllCall("GetCurrentProcess", "Ptr"), "UInt")
		AssertTrue(this.Priority != 0, "the fixture must preserve its actual driver priority")
		_LLM_Deps_FailureMessage := "terminal-delivery-unpublished"
		this.Runtime := _ORT_Fixture()
		this.Bootstrap := _G4B_Fixture()
		this.Adapter := _ORTD_Runtime(this)
		this.Bootstrap.Runtime := this.Adapter
		this.Mode := Mode
		this.Deliveries := 0
		this.TimerCalls := 0
		this.TimerFailure := ""
		this.CancelTimer := ObjBindMethod(this, "Revoke")
	}
	Start() {
		this.Bootstrap.Start()
		SetTimer(this.Bootstrap.Flow.Timer, 0)
		this.Target := this.Runtime.Owner.Record["target"].Clone()
		AssertTrue(this.Runtime.Owner.Record["accepted"], "the real flow must admit its exact runtime")
	}
	Revoke() {
		global _LLM_Deps_Epoch
		this.TimerCalls += 1
		try {
			switch this.Mode {
				case "cancel": AssertTrue(this.Bootstrap.Flow.Cancel(), "the real flow must acknowledge exact physical retirement")
				case "withdraw": this.Bootstrap.CurrentValue := false
				case "epoch": _LLM_Deps_Epoch += 1
			}
		} catch as Err
			this.TimerFailure := Err.Message
	}
	Close() {
		global _LLM_Deps_FailureMessage
		SetTimer(this.CancelTimer, 0)
		try {
			this.Bootstrap.Close()
			AssertFalse(this.Runtime.Owner.HasOwner(), "the exact native/file owner must retire before fixture disposal")
		} finally {
			if this.HadMessage
				_LLM_Deps_FailureMessage := this.SavedMessage
			else
				_LLM_Deps_FailureMessage := unset
			Restored := DllCall("SetPriorityClass", "Ptr", DllCall("GetCurrentProcess", "Ptr"), "UInt", this.Priority, "Int")
			this.CancelTimer := 0
			this.Adapter.Callback := 0
			this.Adapter.Fixture := 0
			AssertTrue(Restored, "the fixture must restore the original native priority")
		}
	}
}

_ORTD_Delivery(Mode, ExitCode) {
	global _LLM_Deps_State, _LLM_Deps_FailureMessage, _LLM_Deps_Checking
	PreviousCritical := Critical("On")
	F := 0
	try {
		F := _ORTD_Fixture(Mode)
		F.Start()
		Critical("Off")
		F.Runtime.Done.Call(ExitCode, "", "")
		AssertEqual("", F.TimerFailure, "the real revocation timer must finish normally")
		AssertEqual(1, F.Deliveries, "the callback must be captured by the actual runtime terminal path")
		AssertFalse(F.Runtime.Owner.HasOwner(), "the true terminal path must retire physical ownership")
		AssertEqual(1, F.Runtime.RetireCalls, "exact file retirement is acknowledged once")
		AssertEqual(0, F.Runtime.Stops, "an exited task is never terminated again")
		if Mode == "current" {
			AssertEqual(1, F.Bootstrap.FailedCalls, "a current server exit must still report failure")
			AssertEqual("failed", _LLM_Deps_State)
			AssertFalse(_LLM_Deps_Checking)
			AssertTrue(F.Bootstrap.Flow.Failed)
			AssertTrue(_LLM_Deps_FailureMessage != "terminal-delivery-unpublished")
		} else {
			AssertEqual(1, F.TimerCalls)
			AssertEqual(0, F.Bootstrap.FailedCalls, "a revoked flow cannot publish a stale business failure")
			AssertEqual("pending", _LLM_Deps_State, "revoked work cannot overwrite the caller's dependency state")
			AssertEqual("terminal-delivery-unpublished", _LLM_Deps_FailureMessage)
			AssertTrue(_LLM_Deps_Checking)
			AssertFalse(F.Bootstrap.Flow.Failed, "revoked work cannot claim a current failure")
		}
		F.Runtime.Done.Call(ExitCode, "", "")
		AssertEqual(1, F.Deliveries, "late terminal delivery cannot replay a retired record")
		AssertEqual(Mode == "current" ? 1 : 0, F.Bootstrap.FailedCalls)
		AssertEqual(1, F.Runtime.RetireCalls)
	} finally {
		try {
			if IsObject(F)
				F.Close()
		} finally Critical(PreviousCritical)
	}
}
Test("managed runtime: cancellation before terminal delivery suppresses failure (runtime-terminal-delivery-owner)", _ORTD_Delivery.Bind("cancel", 71))
Test("managed runtime: withdrawn source before terminal delivery suppresses failure (runtime-terminal-delivery-owner)", _ORTD_Delivery.Bind("withdraw", 71))
Test("managed runtime: superseded epoch before terminal delivery suppresses failure (runtime-terminal-delivery-owner)", _ORTD_Delivery.Bind("epoch", 71))
Test("managed runtime: current zero exit still publishes failure once (runtime-terminal-delivery-owner)", _ORTD_Delivery.Bind("current", 0))
Test("managed runtime: current failed exit still publishes failure once (runtime-terminal-delivery-owner)", _ORTD_Delivery.Bind("current", 71))

_ORTD_Retained() {
	global _LLM_Deps_State, _LLM_Deps_FailureMessage
	PreviousCritical := Critical("On")
	F := 0
	try {
		F := _ORTD_Fixture("current")
		F.Start()
		Critical("Off")
		AssertTrue(F.Bootstrap.Flow.Cancel())
		AssertFalse(F.Runtime.Owner.HasOwner())
		F.Adapter.Callback.Call(71, F.Target.Clone())
		AssertEqual(0, F.Bootstrap.FailedCalls, "the exact retained bootstrap callback must refuse retired admission")
		AssertFalse(F.Bootstrap.Flow.Failed)
		AssertEqual("pending", _LLM_Deps_State)
		AssertEqual("terminal-delivery-unpublished", _LLM_Deps_FailureMessage)
		AssertEqual(1, F.Runtime.Stops)
		AssertEqual(1, F.Runtime.RetireCalls)
	} finally {
		try {
			if IsObject(F)
				F.Close()
		} finally Critical(PreviousCritical)
	}
}
Test("managed runtime: retained bootstrap exit callback cannot publish after cancel (runtime-terminal-delivery-owner)", _ORTD_Retained)

_ORTD_ForeignTarget() {
	PreviousCritical := Critical("On")
	F := 0
	try {
		F := _ORTD_Fixture("current")
		F.Start()
		Critical("Off")
		Record := F.Runtime.Owner.Record
		for Name in ["origin", "runtime_ticket", "ticket", "root_identity", "version_identity", "manifest_sha256"] {
			Foreign := F.Target.Clone()
			Foreign[Name] .= "-foreign"
			F.Adapter.Callback.Call(71, Foreign)
			AssertEqual(0, F.Bootstrap.FailedCalls, "a foreign callback cannot fail the admitted target: " . Name)
			AssertFalse(F.Bootstrap.Flow.Cancelled || F.Bootstrap.Flow.Failed)
			AssertTrue(F.Runtime.Owner.Record == Record && IsObject(Record["task"]))
		}
		AssertEqual(0, F.Runtime.Stops, "foreign exit metadata cannot terminate the current runtime")
		F.Runtime.Done.Call(71, "", "")
		AssertEqual(1, F.Bootstrap.FailedCalls, "the actual exact terminal target still reports failure")
		AssertEqual(1, F.Runtime.RetireCalls)
	} finally {
		try {
			if IsObject(F)
				F.Close()
		} finally Critical(PreviousCritical)
	}
}
Test("managed runtime: foreign exit targets preserve the admitted runtime (runtime-terminal-delivery-owner)", _ORTD_ForeignTarget)
