; adapters/editor_replace.ahk

; ==============================================================================
; MODULE: Verified native editor output
; DESCRIPTION:
; Owns asynchronous literal replacement and its completion. Window messages run
; on the DLL worker, never under AutoHotkey Critical or on a keyboard callback.
; A prepared request is admitted again before mutation. Only verified output may
; publish its journal and canonical mirrors; uncertainty invalidates those mirrors
; without retrying through the clipboard or keyboard.
; ==============================================================================

global _TEXT_NATIVE_OWNER := 0
global _TEXT_NATIVE_SERIAL := 0
global _TextSenderNativeTestPort := 0
global TEXT_NATIVE_POLL_MS := 10

/** Returns the current native focused control without sending an editor message. */
_TextSenderNativeFocus() {
	Window := DllCall("User32\GetForegroundWindow", "Ptr")
	Pid := 0
	ThreadId := DllCall("User32\GetWindowThreadProcessId", "Ptr", Window,
		"UInt*", &Pid, "UInt")
	Info := Buffer(8 + 6 * A_PtrSize + 16, 0)
	NumPut("UInt", Info.Size, Info)
	if !ThreadId || !Pid || !DllCall("User32\GetGUIThreadInfo", "UInt", ThreadId,
			"Ptr", Info, "Int")
		throw Error("native editor focus unavailable")
	Control := NumGet(Info, 8 + A_PtrSize, "Ptr")
	if !Control
		throw Error("native editor has no focused control")
	return Map("hwnd", Window, "control", Control, "pid", Pid)
}

/** Resolves an internal test port; it does not extend the shared TextSender port. */
_TextSenderNativePort(Opts) {
	global _TextSenderNativeTestPort
	Port := Opts.Get("native_port", _TextSenderNativeTestPort)
	if Port is Map {
		for Name in ["focus", "begin", "poll", "decide", "close", "schedule"] {
			if !HasMethod(Port.Get(Name, 0), "Call")
				throw TypeError("native editor port is missing " . Name)
		}
		return Port
	}
	return Map("focus", _TextSenderNativeFocus,
		"begin", _TextSenderNativeBegin,
		"poll", _TextSenderNativePollReceipt,
		"decide", _TextSenderNativeDecide,
		"close", _TextSenderNativeClose,
		"schedule", _TextSenderNativeSchedule)
}

_TextSenderNativeBegin(Owner) {
	Focus := Owner.Focus
	return DllCall(_LLM_NavEventOwnerNativeExport("ErgoptiEditor_Begin"),
		"UInt64", Owner.Token, "UInt64", Focus["hwnd"],
		"UInt64", Focus["control"], "UInt", Focus["pid"],
		"WStr", Owner.Opts.Get("deleted_text", ""), "WStr", Owner.Text, "Int")
}

_TextSenderNativePollReceipt(Token) {
	Phase := 0
	PollOsErrorCode := 0
	Status := DllCall(_LLM_NavEventOwnerNativeExport("ErgoptiEditor_Poll"),
		"UInt64", Token, "UInt*", &Phase, "UInt*", &PollOsErrorCode, "Int")
	if Status != 0
		throw Error("native editor poll failed with status " . Status)
	return Map("phase", Phase, "os_error", PollOsErrorCode)
}

_TextSenderNativeDecide(Token, Commit) {
	return DllCall(_LLM_NavEventOwnerNativeExport("ErgoptiEditor_Decide"),
		"UInt64", Token, "UInt", Commit, "Int")
}

_TextSenderNativeClose(Token) {
	return DllCall(_LLM_NavEventOwnerNativeExport("ErgoptiEditor_Close"),
		"UInt64", Token, "Int")
}

_TextSenderNativeSchedule(Callback) {
	global TEXT_NATIVE_POLL_MS
	SetTimer(Callback, -TEXT_NATIVE_POLL_MS)
}

/** Queues one immutable request, returning before any receiver messages execute. */
_TextSenderQueueNative(Text, Opts, Callback) {
	global _TEXT_NATIVE_OWNER, _TEXT_NATIVE_SERIAL
	Options := Opts is Map ? Opts.Clone() : Map()
	try {
		Deleted := Options.Get("deleted_text", "")
		Count := Options.Get("erase_before", 0)
		if !(Text is String) || !(Deleted is String)
			throw TypeError("native editor output requires literal Unicode text")
		if Count > 0 && (!Options.Has("deleted_text")
				|| _TextCodepointLength(Deleted) != Count)
			throw ValueError("native editor erasure requires the exact deleted text")
		if Count == 0 && Deleted != ""
			throw ValueError("native editor deleted text has no erasure owner")
		Port := _TextSenderNativePort(Options)
		Focus := Port["focus"].Call()
		PreviousCritical := Critical("On")
		try {
			if _TEXT_NATIVE_OWNER
				throw Error("another native editor output is pending")
			Owner := { Token: ++_TEXT_NATIVE_SERIAL, Text: Text, Opts: Options,
				Callback: Callback, Port: Port, Focus: Focus,
				Started: false, Decided: false, Done: false, Prepared: 0,
				PrepareError: "", Failure: "", ServiceReported: false,
				Faulted: false, CallbackPublished: false }
			Owner.PollFn := _TextSenderPollNative.Bind(Owner)
			_TEXT_NATIVE_OWNER := Owner
		} finally Critical(PreviousCritical)
		Port["schedule"].Call(Owner.PollFn)
	} catch as Err {
		if IsSet(Owner) && _TEXT_NATIVE_OWNER == Owner
			_TEXT_NATIVE_OWNER := 0
		_TextSenderInvokeCallback(Callback, false, Err.Message)
	}
}

/** Preparation remains on the open timer thread, including journal privacy I/O. */
_TextSenderNativeStartOwner(Owner) {
	if A_IsSuspended || !_TextSenderAdmissionCurrent(Owner.Opts, &Failure)
		throw Error(A_IsSuspended ? "driver suspended before native editor output" : Failure)
	Prepare := Owner.Opts.Get("atomic_prepare", 0)
	if HasMethod(Prepare, "Call") {
		try Owner.Prepared := Prepare.Call()
		catch as Err
			Owner.PrepareError := Err.Message
	}
	if !_TextSenderAdmissionCurrent(Owner.Opts, &Failure)
		throw Error(Failure)
	Status := Owner.Port["begin"].Call(Owner)
	if Status != 0
		throw Error("native editor begin failed with status " . Status)
	Owner.Started := true
}

/** Polling never treats worker startup or mutation dispatch as output success. */
_TextSenderPollNative(Owner) {
	global _TEXT_NATIVE_OWNER
	if Owner.Done || _TEXT_NATIVE_OWNER != Owner
		return
	if Owner.Faulted {
		_TextSenderDrainFaultedNative(Owner)
		return
	}
	try {
		if !Owner.Started
			_TextSenderNativeStartOwner(Owner)
		Receipt := Owner.Port["poll"].Call(Owner.Token)
		Phase := Receipt["phase"]
		if Phase == 2 && !Owner.Decided {
			Admitted := !A_IsSuspended && _TextSenderAdmissionCurrent(Owner.Opts, &Failure)
			if !Admitted
				Owner.Failure := A_IsSuspended ? "driver suspended before native editor mutation" : Failure
			Status := Owner.Port["decide"].Call(Owner.Token, Admitted ? 1 : 0)
			if Status != 0
				throw Error("native editor decision failed with status " . Status)
			Owner.Decided := true
		}
		if Phase >= 4 && Phase <= 6 {
			Closed := Owner.Port["close"].Call(Owner.Token)
			if Closed == 5 {
				Owner.Port["schedule"].Call(Owner.PollFn)
				return
			}
			if Closed != 0
				throw Error("native editor close failed with status " . Closed)
			_TextSenderFinishNative(Owner, Phase, Receipt.Get("os_error", 0))
			return
		}
		if Phase < 1 || Phase > 6
			throw Error("native editor returned an invalid phase")
		Owner.Port["schedule"].Call(Owner.PollFn)
	} catch as Err {
		if !Owner.Started {
			_TextSenderFinishNative(Owner, 5, 0, Err.Message)
			return
		}
		; Do not free a live native job or launch a replacement sender. A native
		; admission timeout settles a worker whose decision could not be delivered.
		try {
			_TextSenderFaultNative(Owner, Err.Message)
		} finally Owner.Port["schedule"].Call(Owner.PollFn)
	}
}

/** Settles callers once while retaining the live worker's native storage debt. */
_TextSenderFaultNative(Owner, Failure) {
	if Owner.Faulted
		return
	Owner.Faulted := true
	Owner.Failure := Failure
	try {
		_TextSenderNativeRecover(Owner, Failure)
	} finally {
		try LoggerError("TextSender", "Native editor service failed: {1}.", Failure)
		finally {
			Owner.CallbackPublished := true
			_TextSenderInvokeCallback(Owner.Callback, false, Failure)
		}
	}
}

/** Close independently proves thread exit even when the polling transport fails. */
_TextSenderDrainFaultedNative(Owner) {
	try {
		Closed := Owner.Port["close"].Call(Owner.Token)
		if Closed == 0 {
			; A previously admitted worker may have completed after its fault was
			; presented. Invalidate any later mirrors without publishing success.
			_TextSenderFinishNative(Owner, 6, 0, Owner.Failure)
			return
		}
		if Closed != 5
			throw Error("native editor debt close failed with status " . Closed)
	} catch as Err {
		if !Owner.ServiceReported {
			Owner.ServiceReported := true
			try LoggerError("TextSender", "Native editor cleanup remains pending: {1}.", Err.Message)
			finally Owner.Port["schedule"].Call(Owner.PollFn)
			return
		}
	}
	if !Owner.Done
		Owner.Port["schedule"].Call(Owner.PollFn)
}

_TextSenderNativePreparedJournal(Owner) {
	if Owner.PrepareError != ""
		throw Error(Owner.PrepareError)
	return Owner.Prepared
}

/** Invalidates uncertain mirrors under Critical and finishes presentation outside. */
_TextSenderNativeRecover(Owner, Failure) {
	Recovery := Owner.Opts.Get("commit_failure", _TextSenderNativeDefaultRecovery)
	if (Recovery is Integer) && Recovery == 0
		Recovery := _TextSenderNativeDefaultRecovery
	if !HasMethod(Recovery, "Call")
		throw TypeError("native editor recovery must be callable")
	Finalizer := 0
	PreviousCritical := Critical("On")
	try Finalizer := Recovery.Call(Failure)
	finally Critical(PreviousCritical)
	if HasMethod(Finalizer, "Call")
		Finalizer.Call()
}

/** Publishes one terminal callback; a verified receipt is the only success gate. */
_TextSenderFinishNative(Owner, Phase, OsError, Failure := "") {
	global _TEXT_NATIVE_OWNER
	if Owner.Done
		return
	Owner.Done := true
	if _TEXT_NATIVE_OWNER == Owner
		_TEXT_NATIVE_OWNER := 0
	Ok := false
	Message := Failure != "" ? Failure : Owner.Failure
	try {
		if Phase == 4 {
			Options := Owner.Opts.Clone()
			Options["atomic_prepare"] := _TextSenderNativePreparedJournal.Bind(Owner)
			; The OS effect is already independently verified. This RAM-only sender
			; joins the existing journal/commit contract without starting a worker.
			Result := _TextSenderRunAtomicOutput(() => true, Options, "native editor output")
			Ok := Result.Ok
			Message := Result.ErrorMessage
			if Result.Rejected {
				Message := "native editor output completed after its admission changed"
				_TextSenderNativeRecover(Owner, Message)
			}
		} else if Phase == 6 {
			if Message == ""
				Message := "native editor effect is indeterminate; Win32 " . OsError
			_TextSenderNativeRecover(Owner, Message)
		} else if Message == ""
			Message := "native editor precondition refused; Win32 " . OsError
	} catch as Err {
		Message := "native editor settlement failed: " . Err.Message
		LoggerError("TextSender", "{1}.", Message)
	} finally {
		try {
			if !Ok
				LoggerWarn("TextSender", "Native editor output was not committed: {1}.", Message)
		} finally {
			if !Owner.CallbackPublished {
				Owner.CallbackPublished := true
				_TextSenderInvokeCallback(Owner.Callback, Ok, Message)
			}
		}
	}
}

/** Uses the paired canonical RAM recovery when no caller supplied its own hook. */
_TextSenderNativeDefaultRecovery(Failure) {
	global _LLM_Engine
	return _LLM_Bridge_RecoverInjectedState(
		{ Inline: IsSet(_LLM_Engine) && (_LLM_Engine is Map) }, Failure)
}
