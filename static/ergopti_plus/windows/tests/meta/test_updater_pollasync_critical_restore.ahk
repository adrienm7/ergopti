; tests/meta/test_updater_pollasync_critical_restore.ahk

; ==============================================================================
; MODULE: _Updater_PollDownloadAsync Critical Restore Meta Test
; DESCRIPTION:
; Regression guard: _Updater_PollDownloadAsync armed Critical("On") before the
; disk-swap block (stream write, size checks, swap-script write, swap launch)
; but never restored it on any of the six failure branches that return early
; from that region — only the success path reaches ExitApp(0), which never
; returns. A bare Critical("On") with no restore left the ENTIRE driver
; thread uninterruptible (no hotkeys, hotstrings, or timers could preempt it)
; for the rest of the process lifetime after any one of: a stream write
; failure, a missing downloaded file, a partial-download size mismatch, a
; too-small file, a swap-script write failure, or a swap-launch failure.
;
; The fix captures the prior state (_PrevCrit := Critical("On")) and restores
; it (Critical(_PrevCrit)) immediately before each of those six early returns.
;
; SCOPE: source introspection of lib/updater/self_update.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================================================
; =================================================================
; ======= 1/ Every early return restores the prior Critical =======
; =================================================================
; ================================================================

_UPCR_CheckEveryBailoutRestoresCritical() {
	Body := _DriverFuncBody("_Updater_PollDownloadAsync")
	Assert(Body != "", "_Updater_PollDownloadAsync must exist in lib/updater/self_update.ahk")

	ArmPos := InStr(Body, 'Critical("On")')
	Assert(ArmPos > 0, '_Updater_PollDownloadAsync must arm Critical("On") before the disk-swap block')

	; The prior state must be captured so it can be restored, not a bare "On".
	Assert(InStr(Body, "_PrevCrit") > 0,
		'_Updater_PollDownloadAsync must capture the prior Critical state (e.g. _PrevCrit := Critical("On")) so it can be restored on every bail-out')

	; Every "return" after the arm point must be preceded by a restore, except
	; the final unconditional success path which reaches ExitApp(0) and never
	; returns normally. Count occurrences of "Critical(_PrevCrit)" restores and
	; compare against the number of early "return" statements between the arm
	; point and the terminal ExitApp(0) call.
	Tail := SubStr(Body, ArmPos)
	ExitPos := InStr(Tail, "ExitApp(0)")
	Assert(ExitPos > 0, "_Updater_PollDownloadAsync must still terminate via ExitApp(0) on the success path")

	Guarded := SubStr(Tail, 1, ExitPos - 1)

	ReturnCount := 0
	SearchPos := 1
	Loop {
		Pos := InStr(Guarded, "return", , SearchPos)
		if !Pos
			break
		ReturnCount += 1
		SearchPos := Pos + 6
	}
	Assert(ReturnCount >= 6,
		'_Updater_PollDownloadAsync must still have all six pre-swap failure branches '
		. '(stream write, missing file, partial-download, too-small file, swap-script write, '
		. 'swap-launch) between Critical("On") and ExitApp(0) — found ' . ReturnCount)

	RestoreCount := 0
	SearchPos := 1
	Loop {
		Pos := InStr(Guarded, "Critical(_PrevCrit)", , SearchPos)
		if !Pos
			break
		RestoreCount += 1
		SearchPos := Pos + 1
	}
	Assert(RestoreCount >= ReturnCount,
		'_Updater_PollDownloadAsync must restore Critical(_PrevCrit) immediately before EVERY early '
		. 'return between Critical("On") and ExitApp(0) (found ' . RestoreCount . ' restores for '
		. ReturnCount . ' returns) — otherwise a download failure leaves the whole driver thread '
		. 'permanently uninterruptible')
}
Test("updater: _Updater_PollDownloadAsync restores Critical on every disk-swap bail-out (updater-critical-leak)",
	_UPCR_CheckEveryBailoutRestoresCritical)
