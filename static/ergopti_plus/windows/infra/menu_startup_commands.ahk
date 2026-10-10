; infra/menu_startup_commands.ahk

; ==============================================================================
; MODULE: Menu Startup Command Admission
; DESCRIPTION:
; Show configured menus before input registration without letting their commands
; mutate partially initialized state. Accepted actions retain registration identity
; until the actual input owner releases them; lifecycle actions remain available.
; ==============================================================================

#Requires AutoHotkey v2.0

global _MenuStartupCommands := false

/** Marks lifecycle commands whose existing owner supports incomplete startup. */
class MenuStartupSafeCommand {
	__New(Callback) {
		if !HasMethod(Callback, "Call")
			throw TypeError("Startup-safe menu commands must be callable")
		this.Callback := Callback
	}

	Call(Args*) {
		return this.Callback.Call(Args*)
	}
}

/** Admits a read-only window after its cleanup owner exists, before input readiness. */
class MenuStartupUiCommand extends MenuStartupSafeCommand {
	__New(Callback, ReadyFn) {
		super.__New(Callback)
		if !HasMethod(ReadyFn, "Call")
			throw TypeError("Early UI commands require their own readiness owner")
		this.ReadyFn := ReadyFn
	}
}

/** Certifies diagnostic cleanup independently of hotstring registration. */
MenuStartupDiagnosticsReady() {
	global _DriverUiCleanupReady, _DriverMenuReady
	return IsSet(_DriverUiCleanupReady) && _DriverUiCleanupReady
		&& IsSet(_DriverMenuReady) && _DriverMenuReady
}

/** Explicitly declares the one toggle whose unchanged early presentation joins repeated clicks. */
class MenuStartupRepeatableToggleCommand {
	__New(Id, Callback) {
		if !(Id is String) || !(Id == "llm_toggle") || !HasMethod(Callback, "Call")
			throw TypeError("Repeatable startup selection requires the declared AI toggle")
		this.Id := Id
		this.Callback := Callback
	}

	Call(Args*) {
		return this.Callback.Call(Args*)
	}
}

/** Retains bounded command intents until input initialization genuinely completes. */
class MenuStartupCommands {
	__New(ReadyFn, ScheduleFn := 0) {
		if !HasMethod(ReadyFn, "Call")
			throw TypeError("Menu startup admission requires a readiness owner")
		this.ReadyFn := ReadyFn
		this.ScheduleFn := HasMethod(ScheduleFn, "Call") ? ScheduleFn : SetTimer
		this.Pending := []
		this.Released := false
		this.Canceled := false
		this.Generation := 0
	}

	/** Retains one explicitly accepted selection, independently of retry dispatch. */
	Retain(Callback, Args, Registration := 0) {
		static MAX_PENDING := 16
		if !HasMethod(Callback, "Call") || !(Args is Array)
			throw TypeError("A startup menu selection requires a callable and arguments")
		PreviousCritical := Critical("On")
		try {
			if this.Canceled
				throw Error("Startup menu selection ownership was canceled")
			if this.Released
				return false
			Identity := IsObject(Registration)
				? {ItemId: Registration.ItemId, Token: Registration.Token} : 0
			RepeatCallback := Callback is MenuStartupRepeatableToggleCommand ? Callback.Callback : 0
			RepeatId := Callback is MenuStartupRepeatableToggleCommand ? Callback.Id : ""
			if RepeatId == "llm_toggle" && IsObject(Identity)
					&& (Identity.ItemId is Integer) && Identity.ItemId > 0
					&& (Identity.Token is Integer) && Identity.Token > 0 {
				for Entry in this.Pending {
					if Entry.HasOwnProp("RepeatId") && Entry.RepeatId == RepeatId
							&& Entry.RepeatCallback == RepeatCallback && IsObject(Entry.Identity)
							&& Entry.Identity.ItemId == Identity.ItemId && Entry.Identity.Token == Identity.Token {
						try LoggerInfo("MenuDispatcher", "Repeated pending AI toggle joined the retained selection.")
						return true
					}
				}
			}
			if this.Pending.Length >= MAX_PENDING
				throw Error("Startup menu selection capacity was exceeded")
			this.Pending.Push({Callback: Callback, Args: Args.Clone(), Identity: Identity,
				RepeatId: RepeatId, RepeatCallback: RepeatCallback, AcceptedAt: A_TickCount})
			try LoggerInfo("MenuDispatcher", "Menu selection retained until input initialization completes; {1} pending.",
				this.Pending.Length)
			return true
		} finally Critical(PreviousCritical)
	}

	/** Releases accepted selections only after the input readiness contract exists. */
	NotifyReady() {
		global _TrayStartupCommands
		if this.Canceled
			throw Error("Canceled startup menu selections cannot be released")
		if !this.ReadyFn.Call()
			throw Error("Menu selections cannot be released before input readiness")
		if this.Released
			return false
		Entries := this.Pending
		if IsSet(_TrayStartupCommands) && _TrayStartupCommands is TrayStartupCommands
				&& _TrayStartupCommands.Pending != "" {
			try LoggerWarn("MenuDispatcher", "Retained feature selections superseded by the accepted startup lifecycle command '{1}'.",
				_TrayStartupCommands.Pending)
			Entries := []
		}
		this.Pending := []
		this.Released := true
		if Entries.Length > 0 {
			try this.ScheduleFn.Call(ObjBindMethod(this, "Drain", Entries, this.Generation), -1)
			catch as Err {
				this.Pending := Entries
				this.Released := false
				try LoggerError("MenuDispatcher", "Retained startup selections could not be scheduled: {1}.", Err.Message)
				throw Err
			}
		}
		return true
	}

	/** Runs retained selections once, refusing registrations retired in the meantime. */
	Drain(Entries, Generation, *) {
		global _MenuDispatchTokens
		global _SuspendPending
		for Entry in Entries {
			if Generation != this.Generation
				return false
			Identity := Entry.Identity
			if A_IsSuspended || (IsSet(_SuspendPending) && _SuspendPending) || (IsObject(Identity)
					&& (!_MenuDispatchTokens.Has(Identity.ItemId)
						|| _MenuDispatchTokens[Identity.ItemId] != Identity.Token)) {
				try LoggerWarn("MenuDispatcher", "Retained startup selection refused: the driver is paused or its registration retired.")
				continue
			}
			try LoggerInfo("MenuDispatcher", "Retained startup selection runs after {1} ms.",
				TickElapsed(Entry.AcceptedAt))
			MenuCommandRun(Entry.Callback, Entry.Args, 0, 0, 0, Identity)
		}
		return true
	}

	/** Cancels retained and already scheduled intents when their driver exits. */
	Cancel() {
		this.Canceled := true
		this.Generation += 1
		this.Pending := []
		try LoggerDebug("MenuDispatcher", "Startup menu selection ownership canceled.")
	}
}

/** Keeps early terminal actions with the existing startup lifecycle owner. */
MenuStartupLifecycleDispatch(Id, Callback, Args*) {
	global _TrayStartupCommands
	if IsSet(_TrayStartupCommands) && HasMethod(_TrayStartupCommands, "Request")
		return _TrayStartupCommands.Request(Id)
	return Callback.Call(Args*)
}

/** Cancels intents only on accepted terminal teardown, after refusal checks. */
MenuStartupCommands_Shutdown() {
	global _MenuStartupCommands
	if _MenuStartupCommands is MenuStartupCommands
		_MenuStartupCommands.Cancel()
}

/** Starts exactly one admission owner before publishing the early full root. */
MenuStartupCommands_Begin(ReadyFn) {
	global _MenuStartupCommands
	if _MenuStartupCommands
		throw Error("Startup menu command admission already has an owner")
	_MenuStartupCommands := MenuStartupCommands(ReadyFn)
}

/** Tests the explicit startup owner; ordinary driver and test commands stay unchanged. */
MenuStartupCommands_Defer(Callback, Args, Registration := 0) {
	global _MenuStartupCommands
	if !_MenuStartupCommands
		return false
	if !(_MenuStartupCommands is MenuStartupCommands)
		throw TypeError("Startup menu commands require a valid admission owner")
	if Callback is MenuStartupUiCommand
		return !Callback.ReadyFn.Call() && _MenuStartupCommands.Retain(Callback, Args, Registration)
	return !(Callback is MenuStartupSafeCommand)
		&& _MenuStartupCommands.Retain(Callback, Args, Registration)
}
