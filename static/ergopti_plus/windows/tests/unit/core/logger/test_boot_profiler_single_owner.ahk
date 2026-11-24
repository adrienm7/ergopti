; tests/unit/core/logger/test_boot_profiler_single_owner.ahk

; ==============================================================================
; MODULE: Boot Profiler Single Owner Tests
; DESCRIPTION:
; BootProfile_Begin owns the boot clock once (BPF-04 of the 2026-11-24 boot
; profiler parity campaign). It used to restart silently on a second call,
; dropping every phase measured so far and shrinking the boot total, where
; macOS and Linux raise « boot has a single owner ». These cases call the real
; profiler and restore its state through the test seam afterwards.
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
