; static/ergopti_plus/windows/tests/unit/test_siho_boot_window.ahk

; ============================================================================
; MODULE: Suppressive-Hook Boot Window Regression Test
; DESCRIPTION:
; Every remap and digit-row hotkey is live from the moment the script loads, and
; each emitted character asks _EmitReachedScreen whether a suppressive hook ate
; it. That question reaches SIHO_Count, whose registry is created a thousand
; lines further down the boot include list. Pressing "1" a second into startup
; therefore raised UnsetError inside a hotkey thread; the pre-ready error net
; treats an uncaught error as fatal, so the driver logged
; "Fatal startup error during phase 'starting'", showed a modal, and exited.
;
; The shared runner cannot observe that state: it has already executed the
; module's include, so the global is set for every test in the process. The
; harness runs in its own AutoHotkey process with the include placed after the
; probe, which is the only way to reach the real pre-initialisation window.
; ============================================================================

#Requires AutoHotkey v2.0

class _SIHOBW_Hook {
	__New(Name) {
		this.Name := Name
		this.StartCalls := 0
		this.StopCalls := 0
	}

	Start() {
		this.StartCalls += 1
	}

	Stop() {
		this.StopCalls += 1
	}
}

_SIHOBootWindowRun() {
	Harness := A_ScriptDir . "\startup\siho_boot_window_smoke.ahk"
	AssertTrue(FileExist(Harness) != "",
		"the suppressive-hook boot-window harness must exist")
	Command := Chr(34) . A_AhkPath . Chr(34) . " " . Chr(34) . Harness . Chr(34)
	ExitCode := RunWait(Command, A_ScriptDir, "Hide")
	AssertEqual(0, ExitCode,
		"a suppressive-hook query from a hotkey thread must survive the window "
		. "before the registry's include runs: one digit typed during boot used "
		. "to kill the driver (siho-count-before-include)")
}
Test("SIHO boot window: the owner count answers before its registry exists (siho-count-before-include)",
	_SIHOBootWindowRun)

_SIHOCountTracksRealOwnership() {
	; The guard must not degenerate into a blanket zero: once the registry
	; exists the count has to follow real registrations, or _EmitReachedScreen
	; would record characters a suppressing hook actually ate.
	Before := SIHO_Count()
	Hook := _SIHOBW_Hook("siho-boot-window-probe")
	Token := SIHO_StartOwned(Hook, "siho-boot-window-probe")
	AssertTrue(Token > 0, "the probe owner must be admitted by the registry")
	try {
		AssertEqual(Before + 1, SIHO_Count(),
			"registering an owner must raise the live count")
		AssertTrue(SIHO_HasActive(),
			"a registered suppressive owner must report as active")
	} finally {
		SIHO_StopOwned(Token, Hook)
	}
	AssertEqual(Before, SIHO_Count(),
		"stopping the owner must return the count to its previous value")
}
Test("SIHO boot window: the guard still tracks real ownership (siho-count-before-include)",
	_SIHOCountTracksRealOwnership)
