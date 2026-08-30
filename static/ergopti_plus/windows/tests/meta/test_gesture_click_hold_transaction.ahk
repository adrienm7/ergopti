; tests/meta/test_gesture_click_hold_transaction.ahk

; ==============================================================================
; MODULE: Gesture Click-Hold Transaction Meta Test
; DESCRIPTION:
; Guards the click-hold acquisition and release transaction.
;
; A synthetic mouse button must be the final successful setup step because a
; failed InputHook or HookDispatcher registration after Click Down leaves Windows
; dragging indefinitely. The release path may clear state only after its
; matching Up was accepted, preserving retry ownership across native refusal.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================================
; ====================================================
; ======= 1/ Transaction ordering assertions =========
; ====================================================
; ====================================================

_GCHT_AssertTransaction(Button, ToggleName, ReleaseName, FlagName) {
	Q := Chr(34)
	ToggleBody := _DriverFuncBody(ToggleName)
	ReleaseBody := _DriverFuncBody(ReleaseName)
	Assert(ToggleBody != "", ToggleName . " must exist")
	Assert(ReleaseBody != "", ReleaseName . " must exist")
	Down := "Click(" . Q . Button . Q . ", " . Q . "Down" . Q . ")"
	Up := "Click(" . Q . Button . Q . ", " . Q . "Up" . Q . ")"
	DownIdx := InStr(ToggleBody, Down)
	StartIdx := InStr(ToggleBody, "GestureStartKeyboardWatcher()")
	FirstRegisterIdx := InStr(ToggleBody, "HookDispatcher.Register")
	CatchIdx := InStr(ToggleBody, "catch as e")
	Assert(DownIdx > StartIdx and DownIdx > FirstRegisterIdx,
		ToggleName . " must acquire " . Button . " only after watcher and dispatcher setup (gesture-click-hold-transaction)")
	Assert(CatchIdx > DownIdx and InStr(SubStr(ToggleBody, CatchIdx), Up) > 0,
		ToggleName . " rollback must issue " . Button . " Up after a setup failure (gesture-click-hold-transaction)")
	RollbackBody := SubStr(ToggleBody, CatchIdx)
	RollbackUpIdx := InStr(RollbackBody, Up)
	RollbackUnregisterIdx := InStr(RollbackBody, "HookDispatcher.Unregister")
	Assert(RollbackUpIdx > 0 and RollbackUnregisterIdx > RollbackUpIdx,
		ToggleName . " rollback must retain its recovery subscriptions until the compensating Up succeeds (gesture-click-release-debt)")
	Assert(InStr(SubStr(ToggleBody, DownIdx), FlagName . " := True") > 0,
		ToggleName . " must publish held state only after the matching Down (gesture-click-hold-transaction)")
	UpIdx := InStr(ReleaseBody, Up)
	ClearIdx := InStr(ReleaseBody, FlagName . " := False")
	Assert(UpIdx > 0 and ClearIdx > UpIdx,
		ReleaseName . " must retain held state until the native matching Up succeeds; clearing it first loses the only retry owner after a refused release (gesture-click-release-debt)")
	Assert(InStr(ReleaseBody, "if ReleaseSucceeded and") > ClearIdx,
		ReleaseName . " must retire the keyboard retry owner only after the native release transaction committed (gesture-click-release-debt)")
}

_GCHT_LeftTransaction() {
	_GCHT_AssertTransaction("Left", "GestureToggleLeftClick", "GestureReleaseLeftClick", "GestureLeftClickHeld")
}
Test("gestures: left click-hold acquires only after setup and rolls back on failure (gesture-click-hold-transaction)", _GCHT_LeftTransaction)

_GCHT_RightTransaction() {
	_GCHT_AssertTransaction("Right", "GestureToggleRightClick", "GestureReleaseRightClick", "GestureRightClickHeld")
}
Test("gestures: right click-hold acquires only after setup and rolls back on failure (gesture-click-hold-transaction)", _GCHT_RightTransaction)

_GCHT_KeypressRetainsRecoveryHookUntilReleaseSettles() {
	Body := _DriverFuncBody("GestureOnKeyDown")
	Assert(Body != "", "GestureOnKeyDown must exist")
	Assert(InStr(Body, "ih.Stop()") = 0,
		"the keypress observer must remain live until both release transactions settle; stopping it first removes the retry path when Button Up is refused (gesture-click-release-debt)")
}
Test("gestures: keypress release retains its recovery hook until native Up settles (gesture-click-release-debt)",
	_GCHT_KeypressRetainsRecoveryHookUntilReleaseSettles)

_GCHT_AbsentHoldsAcknowledgeRelease() {
	global GestureLeftClickHeld, GestureRightClickHeld, GestureKeyboardHook
	SavedLeft := GestureLeftClickHeld
	SavedRight := GestureRightClickHeld
	SavedHook := GestureKeyboardHook
	try {
		GestureLeftClickHeld := false
		GestureRightClickHeld := false
		GestureKeyboardHook := 0
		AssertTrue(GestureReleaseLeftClick(),
			"an absent left hold must acknowledge terminal release")
		AssertTrue(GestureReleaseRightClick(),
			"an absent right hold must acknowledge terminal release")
	} finally {
		GestureLeftClickHeld := SavedLeft
		GestureRightClickHeld := SavedRight
		GestureKeyboardHook := SavedHook
	}
}
Test("gestures: absent click holds acknowledge idempotent release (gesture-click-release-debt)",
	_GCHT_AbsentHoldsAcknowledgeRelease)

_GCHT_LifecycleRequiresNativeReleaseReceipts() {
	SuspendBody := _DriverFuncBody("Ergopti_OnSuspendEnter")
	ShutdownBody := _DriverFuncBody("Ergopti_OnShutdown")
	DispatchBody := _DriverFuncBody("GestureDispatch")
	Assert(InStr(SuspendBody,
		'() => GestureReleaseLeftClick(), true') > 0
		and InStr(SuspendBody,
			'() => GestureReleaseRightClick(), true') > 0,
		"suspend must record explicit debt when either native Button Up is refused")
	Assert(InStr(ShutdownBody, "LeftHoldReleased") > 0
		and InStr(ShutdownBody, "RightHoldReleased") > 0
		and InStr(ShutdownBody,
			"Shutdown refused because a synthetic mouse button release remains pending") > 0,
		"shutdown must refuse terminal exit while either native Button Up remains pending")
	Assert(InStr(DispatchBody, "LeftReleased := GestureReleaseLeftClick()") > 0
		and InStr(DispatchBody, "RightReleased := GestureReleaseRightClick()") > 0
		and InStr(DispatchBody, "if !LeftReleased or !RightReleased") > 0,
		"a new gesture action must not run while an earlier synthetic button remains down")
}
Test("gestures: lifecycle and dispatch require native click-release receipts (gesture-click-release-debt)",
	_GCHT_LifecycleRequiresNativeReleaseReceipts)

class _GCHT_RefusingKeyboardHook {
	__New() {
		this.StopCalls := 0
	}

	Stop() {
		this.StopCalls += 1
		throw Error("injected stop refusal")
	}
}

class _GCHT_AcceptingKeyboardHook {
	__New() {
		this.StopCalls := 0
	}

	Stop() {
		this.StopCalls += 1
	}
}

_GCHT_KeyboardStopRefusalRetainsExactOwner() {
	global GestureKeyboardHook
	SavedHook := GestureKeyboardHook
	RefusingHook := _GCHT_RefusingKeyboardHook()
	GestureKeyboardHook := RefusingHook
	try {
		AssertFalse(GestureStopKeyboardWatcher(),
			"a refused InputHook stop must remain non-terminal")
		AssertEqual(1, RefusingHook.StopCalls,
			"the exact keyboard watcher must receive one stop attempt")
		AssertTrue(GestureKeyboardHook == RefusingHook,
			"a refused stop must retain the exact live hook for retry")
	} finally {
		GestureKeyboardHook := SavedHook
	}
}
Test("gestures: keyboard watcher stop refusal retains the exact owner (gesture-keywatcher-stop-debt)",
	_GCHT_KeyboardStopRefusalRetainsExactOwner)

_GCHT_KeyboardStopSuccessRetiresExactOwner() {
	global GestureKeyboardHook
	SavedHook := GestureKeyboardHook
	AcceptingHook := _GCHT_AcceptingKeyboardHook()
	GestureKeyboardHook := AcceptingHook
	try {
		AssertTrue(GestureStopKeyboardWatcher(),
			"an accepted InputHook stop must acknowledge terminal cleanup")
		AssertEqual(1, AcceptingHook.StopCalls)
		AssertEqual(0, GestureKeyboardHook,
			"only an accepted stop may retire the exact hook owner")
	} finally {
		GestureKeyboardHook := SavedHook
	}
}
Test("gestures: accepted keyboard watcher stop retires the exact owner (gesture-keywatcher-stop-debt)",
	_GCHT_KeyboardStopSuccessRetiresExactOwner)

_GCHT_StartCannotReplaceRefusedOwner() {
	Body := _DriverFuncBody("GestureStartKeyboardWatcher")
	StopGateIdx := InStr(Body, "if !GestureStopKeyboardWatcher()")
	ConstructIdx := InStr(Body, 'InputHook("V L3")')
	PublishIdx := InStr(Body, "GestureKeyboardHook := Hook")
	StartIdx := InStr(Body, "Hook.Start()")
	Assert(StopGateIdx > 0 and ConstructIdx > StopGateIdx,
		"a refused old watcher must block construction of its replacement")
	Assert(PublishIdx > ConstructIdx and StartIdx > PublishIdx,
		"a new watcher must publish exact cleanup ownership before native Start")
}
Test("gestures: keyboard watcher replacement is fenced by exact stop ownership (gesture-keywatcher-stop-debt)",
	_GCHT_StartCannotReplaceRefusedOwner)
