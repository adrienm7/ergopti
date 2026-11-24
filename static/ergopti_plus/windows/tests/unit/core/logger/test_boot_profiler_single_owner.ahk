; tests/unit/core/logger/test_boot_profiler_single_owner.ahk

; ==============================================================================
; MODULE: Boot Profiler Single Owner Tests
; DESCRIPTION:
; BootProfile_Begin owns the boot clock once (BPF-04 of the 2026-11-24 boot
; profiler parity campaign). It used to restart silently on a second call,
; dropping every phase measured so far and shrinking the boot total, where
; macOS and Linux raise « boot has a single owner »; likewise a second recorded
; completion replaced the logged total where they raise « boot completes once ».
; These cases call the real profiler and restore its state afterwards.
; ==============================================================================

#Requires AutoHotkey v2.0

_BPO_SecondBeginIsRefused() {
	global _BOOT_PROFILE_LAST, _BOOT_PROFILE_START, _BOOT_PROFILE_BEGUN
	SavedStart := _BOOT_PROFILE_START
	SavedLast := _BOOT_PROFILE_LAST
	SavedBegun := _BOOT_PROFILE_BEGUN
	try {
		_BootProfileResetForTest()
		BootProfile_Begin()
		Assert(_BOOT_PROFILE_BEGUN, "the first BootProfile_Begin takes the boot ownership")
		; A past origin makes a silent restart visible: a new A_TickCount differs.
		_BOOT_PROFILE_START := A_TickCount - 5000
		Origin := _BOOT_PROFILE_START
		AssertThrows(() => BootProfile_Begin(),
			"a second BootProfile_Begin must throw instead of restarting the boot clock")
		AssertEqual(Origin, _BOOT_PROFILE_START, "the refused call must keep the boot origin")
		_BootProfileResetForTest()
		BootProfile_Begin()
		Assert(_BOOT_PROFILE_START != Origin, "the test seam releases the ownership for the next test")
	} finally {
		_BOOT_PROFILE_START := SavedStart
		_BOOT_PROFILE_LAST := SavedLast
		_BOOT_PROFILE_BEGUN := SavedBegun
	}
}
Test("boot profiler: a second BootProfile_Begin is refused (bpf-04)", _BPO_SecondBeginIsRefused)

_BPO_SecondCompletionIsRefused() {
	Saved := BootProfile_CompletedBootMs()
	try {
		_BootProfileCompletedStore("reset")
		AssertEqual(-1, BootProfile_CompletedBootMs(), "no boot total before the boot completes")
		AssertEqual(700, BootProfile_CompletedBootMs(700))
		AssertThrows(() => BootProfile_CompletedBootMs(900),
			"a second completion must throw instead of replacing the logged boot total")
		AssertEqual(700, BootProfile_CompletedBootMs(), "the refused completion must keep the first total")
	} finally {
		_BootProfileCompletedStore("reset")
		if (Saved >= 0)
			BootProfile_CompletedBootMs(Saved)
	}
}
Test("boot profiler: a second boot completion is refused (bpf-04)", _BPO_SecondCompletionIsRefused)
