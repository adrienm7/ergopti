; tests/unit/modules/llm/navigation/test_llm_hotkeys_deferred_by_pause.ahk

; ==============================================================================
; MODULE: The AI hotkeys of a menu first built under a pause wait for the resume
; DESCRIPTION:
; Regression for llm-hotkeys-deferred-by-pause (2026-10-01). A driver reloaded
; while paused builds its first tray root under the restored pause. That build
; activates the AI profile and navigation hotkeys, and the native navigation
; owner, suspended by the pause, refuses every plan: the build failed three
; times, the root was retired and the paused driver had no menu. The hotkeys
; cannot fire under a pause, so the first build defers them and the resume
; activates them.
; ==============================================================================

#Requires AutoHotkey v2.0

; Runs an enabled AI with the deferred flag cleared, then restores its owner.
_LHDP_Run(Body) {
	global _LLM_Menu, _LLM_Menu_FirstRestoreHotkeysDeferred, _LLM_Menu_HotkeysAwaitEnable
	Saved := _LLM_Menu_FirstRestoreHotkeysDeferred, SavedMenu := _LLM_Menu
	SavedAwait := _LLM_Menu_HotkeysAwaitEnable
	try {
		_LLM_Menu := Map("enabled", true)
		_LLM_Menu_HotkeysAwaitEnable := false
		_LLM_Menu_FirstRestoreHotkeysDeferred := false
		Body({ Profile: 0, Nav: 0, Activate: 0, Scheduled: [] })
	} finally {
		_LLM_Menu_FirstRestoreHotkeysDeferred := Saved
		_LLM_Menu := SavedMenu, _LLM_Menu_HotkeysAwaitEnable := SavedAwait
	}
}

_LHDP_ProfilePort(Calls) {
	global _LLM_PROFILE_HOTKEY_STATUS_READY
	Calls.Profile += 1
	return _LLM_PROFILE_HOTKEY_STATUS_READY
}

_LHDP_NavPort(Calls) {
	Calls.Nav += 1
	return true
}

_LHDP_PausedFirstBuildDefersTheHotkeys() {
	_LHDP_Run(_Body)
	_Body(Calls) {
		global _LLM_Menu_FirstRestoreHotkeysDeferred
		Profile := _LHDP_ProfilePort.Bind(Calls)
		Nav := _LHDP_NavPort.Bind(Calls)
		AssertTrue(_LLM_Menu_RequireFirstRestoreHotkeys(true, Profile, Nav, true),
			"a first build under a pause must not fail on its hotkeys (llm-hotkeys-deferred-by-pause)")
		AssertEqual(0, Calls.Profile + Calls.Nav,
			"no hotkey owner may be asked for a plan under a pause")
		AssertTrue(_LLM_Menu_FirstRestoreHotkeysDeferred,
			"the activation must be recorded for the resume")

		_LLM_Menu_FirstRestoreHotkeysDeferred := false
		AssertTrue(_LLM_Menu_RequireFirstRestoreHotkeys(false, Profile, Nav, true),
			"a later build under a pause has nothing to activate")
		AssertFalse(_LLM_Menu_FirstRestoreHotkeysDeferred,
			"only the first build defers")

		AssertTrue(_LLM_Menu_RequireFirstRestoreHotkeys(true, Profile, Nav, false),
			"an active driver activates its hotkeys in the first build")
		AssertEqual(1, Calls.Profile, "the profile hotkeys are bound once")
		AssertEqual(1, Calls.Nav, "the navigation hotkeys are bound once")
		AssertFalse(_LLM_Menu_FirstRestoreHotkeysDeferred,
			"an active first build defers nothing")
	}
}
Test("LLM menu: a first build under a pause defers the AI hotkeys (llm-hotkeys-deferred-by-pause)",
	_LHDP_PausedFirstBuildDefersTheHotkeys)

_LHDP_ResumeActivatesTheDeferredHotkeys() {
	_LHDP_Run(_Body)
	_Body(Calls) {
		global _LLM_Menu_FirstRestoreHotkeysDeferred
		Activate := () => (Calls.Activate += 1, true)
		Schedule := (Retry, DelayMs) => Calls.Scheduled.Push(Retry)
		AssertTrue(LLM_Menu_ActivateDeferredHotkeys(Activate, 1, Schedule, false),
			"nothing deferred means nothing to do")
		AssertEqual(0, Calls.Activate)

		_LLM_Menu_FirstRestoreHotkeysDeferred := true
		AssertFalse(LLM_Menu_ActivateDeferredHotkeys(Activate, 1, Schedule, true),
			"a driver paused again keeps the activation for the next resume")
		AssertEqual(0, Calls.Activate)
		AssertTrue(_LLM_Menu_FirstRestoreHotkeysDeferred)

		AssertTrue(LLM_Menu_ActivateDeferredHotkeys(Activate, 1, Schedule, false),
			"the resume must activate the deferred hotkeys (llm-hotkeys-deferred-by-pause)")
		AssertEqual(1, Calls.Activate)
		AssertFalse(_LLM_Menu_FirstRestoreHotkeysDeferred,
			"an activated surface is no longer deferred")
		AssertEqual(0, Calls.Scheduled.Length, "a success schedules no retry")
	}
}
Test("LLM menu: the resume activates the AI hotkeys a pause deferred (llm-hotkeys-deferred-by-pause)",
	_LHDP_ResumeActivatesTheDeferredHotkeys)

_LHDP_RefusedActivationRetriesThenSucceeds() {
	_LHDP_Run(_Body)
	_Body(Calls) {
		global _LLM_Menu_FirstRestoreHotkeysDeferred
		; The native owner is still finishing its resume on the first attempt.
		Activate := () => (Calls.Activate += 1, Calls.Activate >= 2)
		Schedule := (Retry, DelayMs) => Calls.Scheduled.Push(Retry)
		_LLM_Menu_FirstRestoreHotkeysDeferred := true
		AssertFalse(LLM_Menu_ActivateDeferredHotkeys(Activate, 1, Schedule, false),
			"a refused activation is not a success")
		AssertTrue(_LLM_Menu_FirstRestoreHotkeysDeferred,
			"a refused activation stays owed")
		AssertEqual(1, Calls.Scheduled.Length, "a refused activation is retried once")
		Calls.Scheduled[1].Call()
		AssertEqual(2, Calls.Activate)
		AssertFalse(_LLM_Menu_FirstRestoreHotkeysDeferred,
			"the retry that succeeds ends the debt")
		AssertEqual(1, Calls.Scheduled.Length, "a success schedules no further retry")
	}
}
Test("LLM menu: a refused deferred activation is retried (llm-hotkeys-deferred-by-pause)",
	_LHDP_RefusedActivationRetriesThenSucceeds)


; Exercise the actual profile/navigation dispatcher through its existing ports;
; no operating-system hotkey is installed by these ownership scenarios.
_LHDP_EnableNav(Calls) {
	Calls.Nav += 1
	return Calls.Accept
}

_LHDP_EnableCase(Mode) {
	_LHDP_Run(_Body)
	_Body(Calls) {
		global _LLM_Menu, _LLM_Menu_HotkeysAwaitEnable, _LLM_Menu_FirstRestoreHotkeysDeferred
		global LLM_MENU_DEFERRED_HOTKEY_ATTEMPTS
		Calls.Accept := Mode != "retry-off" && Mode != "exhausted"
		Activate := _LLM_Menu_ActivateFirstRestoreHotkeys.Bind(true,
			_LHDP_ProfilePort.Bind(Calls), _LHDP_EnableNav.Bind(Calls))
		Schedule := (Callback, Delay) => Calls.Scheduled.Push({Callback: Callback, Delay: Delay})
		_LLM_Menu_HotkeysAwaitEnable := true
		AssertTrue(LLM_Menu_ScheduleHotkeysAwaitingEnable(Schedule, Activate))
		AssertEqual(-1, Calls.Scheduled[1].Delay)
		if Mode == "initial-off" || Mode == "paused-off"
			_LLM_Menu["enabled"] := false
		if Mode == "paused-off"
			AssertFalse(LLM_Menu_ActivateDeferredHotkeys(Activate, 1, Schedule, true))
		else
			Calls.Scheduled[1].Callback.Call()
		if Mode == "retry-off" || Mode == "exhausted" {
			AssertEqual(1, Calls.Profile)
			AssertEqual(1, Calls.Nav, "the actual navigation dispatcher must have refused the first attempt")
			AssertEqual(2, Calls.Scheduled.Length)
			if Mode == "retry-off" {
				_LLM_Menu["enabled"] := false
				Calls.Scheduled[2].Callback.Call()
			} else {
				Next := 2
				while Next <= Calls.Scheduled.Length {
					Calls.Scheduled[Next].Callback.Call()
					Next += 1
				}
				AssertEqual(LLM_MENU_DEFERRED_HOTKEY_ATTEMPTS, Calls.Nav,
					"the real retry budget must be exhausted without scheduling an unbounded loop")
			}
		}
		Expected := Mode == "exhausted" ? LLM_MENU_DEFERRED_HOTKEY_ATTEMPTS : Mode == "retry-off" ? 1 : 0
		AssertEqual(Expected, Calls.Profile)
		AssertEqual(Expected, Calls.Nav, "a queued callback cannot bind either hotkey family after switch-off")
		AssertTrue(_LLM_Menu_HotkeysAwaitEnable, "unfinished hotkeys must remain available to the next switch-on")
		AssertFalse(_LLM_Menu_FirstRestoreHotkeysDeferred, "the previous callback must relinquish its activation")
		_LLM_Menu["enabled"] := false
		BeforeScheduled := Calls.Scheduled.Length
		AssertFalse(LLM_Menu_ScheduleHotkeysAwaitingEnable(Schedule, Activate))
		AssertEqual(BeforeScheduled, Calls.Scheduled.Length, "AI off never schedules an activation")
		_LLM_Menu["enabled"] := true
		Calls.Accept := true
		AssertTrue(LLM_Menu_ScheduleHotkeysAwaitingEnable(Schedule, Activate),
			"an explicit later switch-on must start a fresh bounded attempt")
		Calls.Scheduled[Calls.Scheduled.Length].Callback.Call()
		AssertEqual(Expected + 1, Calls.Profile)
		AssertEqual(Expected + 1, Calls.Nav)
		AssertFalse(_LLM_Menu_HotkeysAwaitEnable)
		AssertFalse(_LLM_Menu_FirstRestoreHotkeysDeferred)
	}
}

for _LHDP_EnableMode in ["initial-off", "retry-off", "paused-off", "exhausted"]
	Test("LLM deferred hotkeys: " . _LHDP_EnableMode . " retains the next explicit switch-on (llm-deferred-hotkeys-enable-owner)",
		_LHDP_EnableCase.Bind(_LHDP_EnableMode))


_LHDP_DeliverTimer(Calls, Callback) {
	Calls.Deliveries += 1
	Callback.Call()
}

_LHDP_NativeSchedule(Calls, Callback, Delay) {
	Owned := _LHDP_DeliverTimer.Bind(Calls, Callback)
	Calls.Timers.Push(Owned)
	SetTimer(Owned, -Abs(Delay))
}

_LHDP_WaitForDelivery(Calls, Count) {
	Started := A_TickCount
	while Calls.Deliveries < Count && A_TickCount - Started < 2000
		Sleep(1)
	AssertEqual(Count, Calls.Deliveries, "the actual queued timer must deliver its callback within the fixture deadline")
}

_LHDP_NativeEnableCase(Retry) {
	_LHDP_Run(_Body)
	_Body(Calls) {
		global _LLM_Menu, _LLM_Menu_HotkeysAwaitEnable, _LLM_Menu_FirstRestoreHotkeysDeferred
		Calls.Accept := !Retry, Calls.Deliveries := 0, Calls.Timers := []
		Activate := _LLM_Menu_ActivateFirstRestoreHotkeys.Bind(true,
			_LHDP_ProfilePort.Bind(Calls), _LHDP_EnableNav.Bind(Calls))
		Schedule := _LHDP_NativeSchedule.Bind(Calls)
		PreviousCritical := Critical("On"), PreviousSuspend := A_IsSuspended
		try {
			Suspend(false)
			_LLM_Menu_HotkeysAwaitEnable := true
			AssertTrue(LLM_Menu_ScheduleHotkeysAwaitingEnable(Schedule, Activate))
			if Retry {
				Critical("Off")
				_LHDP_WaitForDelivery(Calls, 1)
				AssertEqual(1, Calls.Nav, "the first actual timer must reach a refused navigation binding")
				AssertEqual(2, Calls.Timers.Length, "the refused binding must arm its physical retry")
				Critical("On")
			}
			_LLM_Menu["enabled"] := false
			Critical("Off")
			_LHDP_WaitForDelivery(Calls, Retry ? 2 : 1)
			AssertEqual(Retry ? 1 : 0, Calls.Profile)
			AssertEqual(Retry ? 1 : 0, Calls.Nav, "a physical queued callback must not bind while AI is off")
			AssertTrue(_LLM_Menu_HotkeysAwaitEnable)
			AssertFalse(_LLM_Menu_FirstRestoreHotkeysDeferred)
			Critical("On")
			_LLM_Menu["enabled"] := true, Calls.Accept := true
			AssertTrue(LLM_Menu_ScheduleHotkeysAwaitingEnable(Schedule, Activate))
			Critical("Off")
			_LHDP_WaitForDelivery(Calls, Retry ? 3 : 2)
			AssertEqual(Retry ? 2 : 1, Calls.Profile)
			AssertEqual(Retry ? 2 : 1, Calls.Nav, "a fresh physical callback must still activate both hotkey families")
			AssertFalse(_LLM_Menu_HotkeysAwaitEnable)
			AssertFalse(_LLM_Menu_FirstRestoreHotkeysDeferred)
		} finally {
			for Owned in Calls.Timers
				SetTimer(Owned, 0)
			Suspend(PreviousSuspend), Critical(PreviousCritical)
		}
	}
}

Test("LLM deferred hotkeys: a real queued activation observes switch-off and later switch-on (llm-deferred-hotkeys-enable-owner)",
	_LHDP_NativeEnableCase.Bind(false))
Test("LLM deferred hotkeys: a real retry timer observes switch-off and later switch-on (llm-deferred-hotkeys-enable-owner)",
	_LHDP_NativeEnableCase.Bind(true))
