; tests/unit/test_menu_startup_commands.ahk

; ==============================================================================
; MODULE: Early Configured Menu Command Tests
; DESCRIPTION:
; Exercise command admission, identity retirement, cancellation and lifecycle
; precedence while the complete root is visible before input initialization.
; ==============================================================================

#Requires AutoHotkey v2.0

_MSC_InitializationOwnership() {
	global _MenuStartupCommands
	Saved := _MenuStartupCommands
	try {
		_MenuStartupCommands := false
		AssertFalse(MenuStartupCommands_Defer((*) => 0, []), "ordinary contexts have no startup admission")
		MenuStartupCommands_Begin(() => false)
		Owner := _MenuStartupCommands
		Threw := false
		try MenuStartupCommands_Begin(() => true)
		catch
			Threw := true
		AssertTrue(Threw, "duplicate initialization cannot replace accepted selection ownership")
		AssertTrue(_MenuStartupCommands == Owner)
		_MenuStartupCommands := Map()
		Threw := false
		try MenuStartupCommands_Defer((*) => 0, [])
		catch
			Threw := true
		AssertTrue(Threw, "invalid injected state cannot masquerade as a completed startup")
	} finally _MenuStartupCommands := Saved
}
Test("menu startup: absent, duplicate and invalid initialization retain explicit ownership", _MSC_InitializationOwnership)

_MSC_WithOwner(Body) {
	global _MenuStartupCommands, _TrayStartupCommands, _SuspendPending
	Saved := _MenuStartupCommands
	SavedTray := IsSet(_TrayStartupCommands) ? _TrayStartupCommands : false
	SavedPause := IsSet(_SuspendPending) ? _SuspendPending : false
	State := {Ready: false, Timers: [], Calls: []}
	Owner := MenuStartupCommands(() => State.Ready,
		(Fn, Delay) => State.Timers.Push(Fn))
	try {
		_MenuStartupCommands := Owner
		_TrayStartupCommands := false
		_SuspendPending := false
		Body.Call(Owner, State)
	} finally {
		_MenuStartupCommands := Saved
		_TrayStartupCommands := SavedTray
		_SuspendPending := SavedPause
	}
}

_MSC_RetainsAndReleases(Owner, State) {
	Args := ["first"]
	MenuCommandRun((Value) => State.Calls.Push(Value), Args)
	Args[1] := "changed"
	MenuCommandRun((*) => State.Calls.Push("second"), [])
	AssertEqual(0, State.Calls.Length)
	Threw := false
	try Owner.NotifyReady()
	catch
		Threw := true
	AssertTrue(Threw, "a visible menu must not counterfeit input readiness")
	State.Ready := true
	AssertTrue(Owner.NotifyReady())
	AssertFalse(Owner.NotifyReady())
	AssertEqual(1, State.Timers.Length)
	State.Timers[1].Call()
	AssertEqual(2, State.Calls.Length)
	AssertEqual("first", State.Calls[1], "accepted arguments are copied")
	AssertEqual("second", State.Calls[2], "accepted selections keep FIFO order")
	MenuCommandRun((*) => State.Calls.Push("live"), [])
	AssertEqual(3, State.Calls.Length, "normal dispatch resumes after release")
}
Test("menu startup: selections wait for input readiness and run once in order",
	(*) => _MSC_WithOwner(_MSC_RetainsAndReleases))

_MSC_IdentityAndCancel(Owner, State) {
	global _MenuDispatchTokens
	ItemId := 987654
	Token := 12345
	_MenuDispatchTokens[ItemId] := Token
	try {
		Owner.Retain((*) => State.Calls.Push(1), [], {ItemId: ItemId, Token: Token})
		_MenuDispatchTokens[ItemId] := Token + 1
		State.Ready := true
		Owner.NotifyReady()
		State.Timers[1].Call()
		AssertEqual(0, State.Calls.Length, "retired native registration cannot run")
		Owner.Released := false
		Owner.Retain((*) => State.Calls.Push(2), [])
		Owner.NotifyReady()
		Owner.Cancel()
		State.Timers[2].Call()
		AssertEqual(0, State.Calls.Length, "shutdown cancels already scheduled selections")
	} finally {
		_MenuDispatchTokens.Delete(ItemId)
	}
}
Test("menu startup: native token retirement and shutdown refuse retained callbacks",
	(*) => _MSC_WithOwner(_MSC_IdentityAndCancel))

_MSC_LifecycleWins(Owner, State) {
	global _TrayStartupCommands, _SuspendPending
	_TrayStartupCommands := TrayStartupCommands(() => State.Ready,
		(Id) => State.Calls.Push(Id), (Fn, Delay) => State.Timers.Push(Fn))
	MenuCommandRun((*) => State.Calls.Push("feature"), [])
	Safe := MenuStartupSafeCommand(MenuStartupLifecycleDispatch.Bind("suspend", (*) => 0))
	MenuCommandRun(Safe, [])
	AssertEqual("suspend", _TrayStartupCommands.Pending)
	AssertEqual(1, Owner.Pending.Length, "safe lifecycle dispatch uses its own owner")
	State.Ready := true
	Owner.NotifyReady()
	_TrayStartupCommands.NotifyReady()
	for Fn in State.Timers
		Fn.Call()
	AssertEqual(1, State.Calls.Length)
	AssertEqual("suspend", State.Calls[1], "accepted pause supersedes early feature selections")
	Owner.Released := false
	Owner.Retain((*) => State.Calls.Push("late"), [])
	_SuspendPending := true
	Owner.NotifyReady()
	State.Timers[State.Timers.Length].Call()
	AssertEqual(1, State.Calls.Length, "physical-prefix pause deferral also refuses selection")
}
Test("menu startup: accepted lifecycle commands and pending pause precede feature actions",
	(*) => _MSC_WithOwner(_MSC_LifecycleWins))

_MSC_SchedulingFailure(Owner, State) {
	Owner.Retain((*) => State.Calls.Push(1), [])
	Owner.ScheduleFn := (*) => _MSC_Throw()
	State.Ready := true
	Threw := false
	try Owner.NotifyReady()
	catch
		Threw := true
	AssertTrue(Threw)
	AssertFalse(Owner.Released)
	AssertEqual(1, Owner.Pending.Length, "failed scheduling retains ownership")
	Owner.ScheduleFn := (Fn, Delay) => State.Timers.Push(Fn)
	Owner.NotifyReady()
	State.Timers[1].Call()
	AssertEqual(1, State.Calls.Length)
}
_MSC_Throw() {
	throw Error("injected startup scheduling refusal")
}
Test("menu startup: scheduling failure cannot lose the accepted selection",
	(*) => _MSC_WithOwner(_MSC_SchedulingFailure))
