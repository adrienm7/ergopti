; tests/meta/metrics/ui/test_wpm_boot_show_respects_disable.ahk

; ==============================================================================
; MODULE: WPM Boot Show Respects a Later Disable Meta Test
; DESCRIPTION:
; Regression guard for the Windows WPM parity audit finding WPMW-001. It is read
; from source because a timer deadline and a native menu cannot run without a
; desktop.
;
; The post-ready boot timer called WPMWidget_Show directly. Show forces
; WPMWidget.visible := true, so a widget disabled during the post-ready delay came
; back and re-armed its display timers. The timer now runs WPMWidget_BootShow,
; which reads the committed preference when it fires.
; ==============================================================================

#Requires AutoHotkey v2.0

; Matches the call text of a source slice with its comments removed, so a comment
; that names the call cannot satisfy or defeat an assertion.
_WBD_Code(Name) {
	return _StripFullLineComments(_DriverFuncBody(Name))
}

_WBD_BootArmsGuardedShow() {
	Boot := _DriverSourceNoComments()
	Assert(InStr(Boot, "SetTimer(WPMWidget_BootShow,") > 0,
		"the boot entrypoint must arm the guarded WPMWidget_BootShow timer")
	Assert(InStr(Boot, "SetTimer(WPMWidget_Show,") = 0,
		"the boot entrypoint must not arm the unguarded WPMWidget_Show, which forces the widget visible")
}
Test("wpm-boot-show: boot arms the guarded show, not the forcing one", _WBD_BootArmsGuardedShow)

_WBD_BootShowReadsPreference() {
	Body := _WBD_Code("WPMWidget_BootShow")
	Assert(Body != "", "WPMWidget_BootShow must exist in the wpm display module")
	GuardPos := InStr(Body, "!WPMWidget.visible")
	ShowPos := InStr(Body, "WPMWidget_Show()")
	Assert(GuardPos > 0, "WPMWidget_BootShow must read the committed visible preference when it fires")
	Assert(ShowPos > GuardPos,
		"WPMWidget_BootShow must test the preference BEFORE it calls WPMWidget_Show")
	Assert(InStr(Body, "return") > 0 && InStr(Body, "return") < ShowPos,
		"a disabled widget must return before WPMWidget_Show can restore it")
}
Test("wpm-boot-show: the deferred show honours a disable made after ready", _WBD_BootShowReadsPreference)
