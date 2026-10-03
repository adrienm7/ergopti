; tests/unit/test_boot_menu_wait_clock.ahk

; ==============================================================================
; MODULE: Boot Menu Wait Accounting Tests
; DESCRIPTION:
; Native menu navigation interrupts an unfinished boot. Its reading interval
; must be attributed separately from hook construction or hotstring work, even
; when a timing stage begins or ends while navigation is still active.
; ==============================================================================

#Requires AutoHotkey v2.0

_BMW_AccountsPartialIntervals() {
	Clock := BootMenuWaitClock()
	AssertEqual(0, Clock.Elapsed(10))
	Clock.Enter(100)
	StageStart := Clock.Elapsed(130)
	AssertEqual(30, StageStart)
	AssertEqual(70, Clock.Elapsed(200) - StageStart, "an active menu intersects the stage")
	Clock.Leave(250)
	AssertEqual(150, Clock.Elapsed(1000), "closed navigation stops accumulating")
	Clock.Enter(1100)
	AssertEqual(175, Clock.Elapsed(1125))
	Clock.Leave(1130)
	AssertEqual(180, Clock.Elapsed(2000), "separate navigations accumulate exactly once")
}
Test("boot timing: native menu wait counts partial and repeated intervals (boot-menu-wait)",
	_BMW_AccountsPartialIntervals)

_BMW_RejectsInvalidOwnership() {
	Clock := BootMenuWaitClock()
	AssertThrows(() => Clock.Leave(10), "a missing enter cannot create a negative wait")
	Clock.Enter(100)
	AssertThrows(() => Clock.Enter(200), "duplicate enter cannot overwrite its start")
	Clock.Leave(300)
	AssertThrows(() => Clock.Leave(400), "duplicate leave cannot count the interval twice")
	AssertEqual(200, Clock.Elapsed(500))
}
Test("boot timing: native menu wait rejects duplicate ownership (boot-menu-wait)",
	_BMW_RejectsInvalidOwnership)

_BMW_ProfilerAttributesNativeWait() {
	Begin := _DriverFuncBody("BootProfile_StageBegin")
	Resources := _DriverFuncBody("_BootProfileStageResources")
	Assert(Begin != "" && Resources != "", "production boot timing functions must exist")
	AssertContains(Begin, "MenuWaitMs: BootProfile_MenuWaitMs()")
	AssertContains(Resources, "Started.MenuWaitMs")
	AssertContains(Resources, "native_menu_wait=")
	AssertContains(Resources, "wall_without_menu=")
	Store := _DriverFuncBody("_BootProfileStampStore")
	Assert(Store != "", "the early stamp owner must exist")
	AssertContains(Store, "WallMs: BootClockWallMs()")
	AssertContains(Store, "CpuMs: BootClockCpuMs()")
}
Test("boot timing: stages attribute native navigation and precise early resources (boot-menu-wait)",
	_BMW_ProfilerAttributesNativeWait)
