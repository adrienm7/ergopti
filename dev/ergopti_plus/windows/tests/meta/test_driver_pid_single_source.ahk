; tests/meta/test_driver_pid_single_source.ahk

; ==============================================================================
; MODULE: DriverPid single-source guard
; DESCRIPTION:
; A_Pid is NOT an AHK v2 built-in variable; reading it throws UnsetError. The
; boot code logged an "A_Pid was not set" fallback warning on every single boot
; (23 in 4 days) and GestureRestartTouchpadDevice read it raw, throwing an
; UnsetError that killed touchpad auto-configuration (and, on the tray path,
; reached the error net). The fix routes every PID read through the DriverPid
; global (GetCurrentProcessId), assigned once in the boot pre-pump block. This
; guard asserts that single source exists and that no driver CODE reads A_Pid
; again -- comments are stripped so the explanatory note does not trip it.
; (F08 + F15, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_DPSS_SingleSourceNoUnsetBuiltin() {
	Src := _DriverSourceNoComments()
	Assert(InStr(Src, "global DriverPid :=") > 0,
		"ErgoptiPlus must assign the DriverPid single-source global (GetCurrentProcessId)")
	Assert(InStr(Src, "A_Pid") = 0,
		"no driver code may read A_Pid -- it is not an AHK v2 built-in and throws UnsetError; use DriverPid")
}
Test("boot: DriverPid is the single PID source, A_Pid is never read", _DPSS_SingleSourceNoUnsetBuiltin)
