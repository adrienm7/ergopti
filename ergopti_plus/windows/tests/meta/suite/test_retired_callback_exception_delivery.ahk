; tests/meta/suite/test_retired_callback_exception_delivery.ahk

; ==============================================================================
; MODULE: Retired Callback Exception Delivery
; DESCRIPTION: Receive the complete retained-ready regression callback while a
; borrowed original on_ready function throws after its real retired no-op.
; The fixture factory and callback both remain real and their observers retire
; by identity before restoring the owned test prototype.
; ==============================================================================

#Requires AutoHotkey v2.0

_AMSR_Start(Observation, NativeStart, Self) {
	NativeStart.Call(Self)
	Observation.Starts += 1
	Target := Self.Callback
	if Target.HasOwnProp("Call")
		throw Error("The borrowed ready callback already owns a call override.")
	Observer := _AMSG_Observe.Bind(Observation.Callback)
	Observation.Target := Target
	Observation.Observer := Observer
	Target.DefineProp("Call", {Call: Observer})
}

_AMSR_Receive(Fault) {
	Prototype := _ORRC_Fixture.Prototype
	Original := Prototype.GetOwnPropDesc("Start")
	Observation := {Starts: 0, Callback: {Entries: 0, Completions: 0}, Target: 0, Observer: 0}
	StartObserver := _AMSR_Start.Bind(Observation, Original.Call)
	try {
		if Fault
			Prototype.DefineProp("Start", {Call: StartObserver})
		Threw := false
		try _ORRC_RetiredBootstrapCallback()
		catch Any
			Threw := true
		if Fault {
			AssertEqual(1, Observation.Starts, "the actual fixture must finish starting once")
			AssertEqual(1, Observation.Callback.Entries, "the original retained callback must be reached once")
			AssertEqual(1, Observation.Callback.Completions, "the real retired-ready callback must finish before injection")
		}
		AssertEqual(Fault, Threw, "the complete ready callback regression must reject empty-message errors")
	} finally {
		if Fault {
			if Prototype.GetOwnPropDesc("Start").Call != StartObserver
				throw Error("The test cannot restore a foreign fixture factory.")
			Prototype.DefineProp("Start", Original)
			Target := Observation.Target
			if IsObject(Target) && Target.HasOwnProp("Call") {
				if Target.GetOwnPropDesc("Call").Call != Observation.Observer
					throw Error("The test cannot retire a foreign ready callback observer.")
				Target.DeleteProp("Call")
			}
			Observation.Target := 0
			Observation.Observer := 0
		}
	}
}

Test("retired callback exception: original healthy control (retired-empty-message)", _AMSR_Receive.Bind(false))
Test("retired callback exception: empty failures cannot pass (retired-empty-message)", _AMSR_Receive.Bind(true))
