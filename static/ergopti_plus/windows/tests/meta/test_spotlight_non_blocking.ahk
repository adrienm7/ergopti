; tests/meta/test_spotlight_non_blocking.ahk

#Requires AutoHotkey v2.0

_SNB_AssertNonBlocking() {
	; Move-resilient: locate SpotlightMouseAt() by name via the framework helper
	; instead of a pinned ui/spotlight.ahk read.
	Body := _DriverFuncBody("SpotlightMouseAt")
	Assert(Body != "", "SpotlightMouseAt must exist in ui/spotlight.ahk")
	
	SleepIdx := InStr(Body, "Sleep(")
	Assert(!SleepIdx, "SpotlightMouseAt must not use a blocking Sleep loop (spotlight-blocks-keyboard-thread)")

	Assert(InStr(Body, "_SpotlightPublishStart") > 0,
		"SpotlightMouseAt must publish through the timer-owning session transaction")
	SpotlightSource := _DriverDirConcat("ui/spotlight")
	Assert(InStr(SpotlightSource, "SetTimer(_SpotlightTick") > 0,
		"the published Spotlight session must use a non-blocking dismissal timer (spotlight-blocks-keyboard-thread)")
}

_SNB_AssertSuspendGuard() {
	Body := _DriverFuncBody("_SpotlightTick")
	Assert(Body != "", "_SpotlightTick must exist in ui/spotlight.ahk")
	
	SuspendIdx := InStr(Body, "A_IsSuspended")
	Assert(SuspendIdx > 0, "_SpotlightTick must guard against A_IsSuspended to hide overlay on pause (spotlight-blocks-keyboard-thread)")
}

Test("spotlight: SpotlightMouseAt is non-blocking (spotlight-blocks-keyboard-thread)", _SNB_AssertNonBlocking)
Test("spotlight: _SpotlightTick hides overlay when suspended (spotlight-blocks-keyboard-thread)", _SNB_AssertSuspendGuard)
