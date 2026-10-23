; modules/keystats/keystats_shutdown.ahk

; ==============================================================================
; MODULE: Keystats Shutdown Helpers
; DESCRIPTION:
; Contains testable terminal-teardown boundaries that must convert native
; cleanup exceptions into aggregate debt without skipping durable drains.
; ==============================================================================


; Publish the terminal ownership lease before any other subsystem drains into
; the keystats. The global shutdown handler calls this before the deferred
; hotstring fire queue, and KL_Stop repeats it for direct callers.
KL_BeginShutdown() {
	ShutdownCritical := Critical("On")
	try {
		if !Keystats.initialized
			return false
		if !Keystats._shutting_down {
			Keystats._shutting_down := true
			Keystats.lifecycle_generation += 1
		}
		return true
	} finally {
		Critical(ShutdownCritical)
	}
}

; Rolls back the reversible shutdown lease when an OnExit gate refuses before
; any producer is stopped. Durable rows already drained remain consumed, while
; future keystats callbacks receive a fresh lifecycle generation.
KL_CancelShutdown() {
	ShutdownCritical := Critical("On")
	try {
		if !Keystats.initialized
			return false
		if Keystats._shutting_down {
			Keystats._shutting_down := false
			Keystats.lifecycle_generation += 1
		}
		return true
	} finally {
		Critical(ShutdownCritical)
	}
}

KL_TimerGroupStart(Owner, TimerSpecs, TimerFn := SetTimer,
		GroupName := "keystats") {
	if !IsObject(Owner)
		throw TypeError("keystats timer owner must be an object")
	if !(TimerSpecs is Array) || TimerSpecs.Length = 0
		throw TypeError("keystats timer specifications must be a non-empty Array")
	if !HasMethod(TimerFn, "Call")
		throw TypeError("keystats timer admission port must be callable")

	SeenProperties := Map()
	for Spec in TimerSpecs {
		if !(Spec is Map) || !Spec.Has("property") || !Spec.Has("callback")
				|| !Spec.Has("period")
			throw TypeError("keystats timer specification is incomplete")
		PropertyName := Spec["property"]
		if !(PropertyName is String) || PropertyName = ""
			throw TypeError("keystats timer property must be a non-empty string")
		if SeenProperties.Has(PropertyName)
			throw ValueError("duplicate keystats timer property: " . PropertyName)
		if !HasMethod(Spec["callback"], "Call")
			throw TypeError("keystats timer callback must be callable")
		ShouldArm := !Spec.Has("arm") || Spec["arm"]
		if !IsNumber(Spec["period"]) || (ShouldArm && Spec["period"] = 0)
			throw ValueError("keystats timer period must be non-zero")
		SeenProperties[PropertyName] := true
	}

	AdmissionError := 0
	CleanupErrors := []
	PreviousCritical := Critical("On")
	try {
		for Spec in TimerSpecs {
			PropertyName := Spec["property"]
			if Owner.HasOwnProp(PropertyName)
				return false
		}
		for Spec in TimerSpecs {
			PropertyName := Spec["property"]
			Owner.%PropertyName% := Spec["callback"]
		}
		try {
			for Spec in TimerSpecs {
				if !Spec.Has("arm") || Spec["arm"]
					TimerFn.Call(Spec["callback"], Spec["period"])
			}
		} catch as Err {
			AdmissionError := Err
			; SetTimer can fail after the native boundary has observed the
			; callback. Cancel every published identity, including the call that
			; threw, and retain only owners whose rollback was itself rejected.
			for Spec in TimerSpecs {
				PropertyName := Spec["property"]
				Callback := Spec["callback"]
				try {
					TimerFn.Call(Callback, 0)
					if Owner.HasOwnProp(PropertyName)
						Owner.%PropertyName% := unset
				} catch as CleanupErr {
					CleanupErrors.Push(PropertyName . ": " . CleanupErr.Message)
				}
			}
		}
	} finally {
		Critical(PreviousCritical)
	}
	for Message in CleanupErrors
		try LoggerError("Keystats",
			"Cannot roll back {1} timer group ({2}).", GroupName, Message)
	if IsObject(AdmissionError)
		throw AdmissionError
	return true
}


KL_TimerGroupStop(Owner, PropertyNames, TimerFn := SetTimer,
		GroupName := "keystats") {
	if !IsObject(Owner)
		throw TypeError("keystats timer owner must be an object")
	if !(PropertyNames is Array)
		throw TypeError("keystats timer properties must be an Array")
	if !HasMethod(TimerFn, "Call")
		throw TypeError("keystats timer cancellation port must be callable")

	CleanupErrors := []
	PreviousCritical := Critical("On")
	try {
		for PropertyName in PropertyNames {
			if !(PropertyName is String) || PropertyName = ""
				throw TypeError("keystats timer property must be a non-empty string")
			if !Owner.HasOwnProp(PropertyName)
				continue
			Callback := Owner.%PropertyName%
			if !HasMethod(Callback, "Call") {
				CleanupErrors.Push(PropertyName . ": owned value is not callable")
				continue
			}
			try {
				TimerFn.Call(Callback, 0)
				; Cancellation and owner retirement are one transaction. A failed
				; native call leaves this exact identity available to the next Stop.
				if Owner.HasOwnProp(PropertyName)
					Owner.%PropertyName% := unset
			} catch as Err {
				CleanupErrors.Push(PropertyName . ": " . Err.Message)
			}
		}
	} finally {
		Critical(PreviousCritical)
	}
	for Message in CleanupErrors
		try LoggerError("Keystats",
			"Cannot stop {1} timer group ({2}).", GroupName, Message)
	return CleanupErrors.Length = 0
}
