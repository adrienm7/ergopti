; tests/meta/test_altgr_reregister_guard.ahk

; ==============================================================================
; MODULE: AltGr Shortcut Re-Registration Guard Meta Test
; DESCRIPTION:
; Static source guard for the finding
; altgr-shortcut-hotkeys-reregister-unguarded.
;
; _RegisterAltGrShortcutsHotkeys() dynamically binds the SC138 + LAlt / CapsLock
; combos through Hotkey() + HotIf(). Today it runs exactly once per process (at
; module include time, after onboarding), but the AltGr layer already performs
; in-process re-arming elsewhere. A second call would stack a fresh HotIf
; closure on the same SC138 combos, orphaning the previous criterion and
; silently shifting the SC138-as-prefix latch semantics, with no log to trace
; when registration ran.
;
; The fix adds a module-level `_AltGrShortcutsRegistered` latch: a duplicate
; call warns and returns instead of re-binding, and the registration body is
; wrapped in a LoggerStart / LoggerSuccess pair so any future double-call is
; visible in the log.
;
; This is a meta-static test (scans source text) rather than a behavioral one:
; the production top-level `_RegisterAltGrShortcutsHotkeys()` call already fired
; at include time, so the live latch is already true and re-invoking the
; function in-process would only exercise the no-op branch. Asserting the guard
; code itself is present in the source is the robust, load-safe encoding of the
; root cause.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_AGRG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Guard assertions =======================
; ===================================================
; ===================================================

_AGRG_HasRegisteredLatch() {
	Src := _AGRG_ReadSource("modules/shortcuts/altgr.ahk")
	Assert(InStr(Src, "global _AltGrShortcutsRegistered") > 0,
		"altgr.ahk must declare a module-level _AltGrShortcutsRegistered latch so the dynamic SC138 registration cannot run twice (altgr-shortcut-hotkeys-reregister-unguarded)")
}
Test("Shortcuts/altgr: module declares _AltGrShortcutsRegistered latch (altgr-shortcut-hotkeys-reregister-unguarded)", _AGRG_HasRegisteredLatch)

_AGRG_DuplicateCallWarnsAndReturns() {
	Src := _AGRG_ReadSource("modules/shortcuts/altgr.ahk")
	Seg := _DriverFuncBody("_RegisterAltGrShortcutsHotkeys")
	Assert(Seg != "", "_RegisterAltGrShortcutsHotkeys() declaration must exist in altgr.ahk")
	Assert(InStr(Seg, "if _AltGrShortcutsRegistered") > 0,
		"_RegisterAltGrShortcutsHotkeys must guard on _AltGrShortcutsRegistered and bail before re-binding the SC138 combos (altgr-shortcut-hotkeys-reregister-unguarded)")
	Assert(InStr(Seg, "LoggerWarn") > 0,
		"_RegisterAltGrShortcutsHotkeys must LoggerWarn on a duplicate call so the silent double registration becomes visible in the log")
}
Test("Shortcuts/altgr: duplicate _RegisterAltGrShortcutsHotkeys warns and returns (altgr-shortcut-hotkeys-reregister-unguarded)", _AGRG_DuplicateCallWarnsAndReturns)

_AGRG_RegistrationIsLogged() {
	Src := _AGRG_ReadSource("modules/shortcuts/altgr.ahk")
	Seg := _DriverFuncBody("_RegisterAltGrShortcutsHotkeys")
	Assert(Seg != "", "_RegisterAltGrShortcutsHotkeys() declaration must exist in altgr.ahk")
	Assert(InStr(Seg, "LoggerStart") > 0,
		"_RegisterAltGrShortcutsHotkeys must LoggerStart so dynamic AltGr registration is traceable")
	Assert(InStr(Seg, "LoggerSuccess") > 0,
		"_RegisterAltGrShortcutsHotkeys must LoggerSuccess (paired with LoggerStart) so an exception during Hotkey() binding surfaces as a missing SUCCESS in the log")
	; The success marker must also flip the latch so the next call short-circuits.
	Assert(InStr(Seg, "_AltGrShortcutsRegistered := true") > 0,
		"_RegisterAltGrShortcutsHotkeys must set _AltGrShortcutsRegistered := true after a successful registration")
}
Test("Shortcuts/altgr: AltGr combo registration is wrapped in a LoggerStart/Success pair (altgr-shortcut-hotkeys-reregister-unguarded)", _AGRG_RegistrationIsLogged)

; Regression: both Hotkey() calls used a bare `try` with no `catch`, so a
; failed registration (invalid syntax, duplicate binding, permission issue)
; was silently swallowed and execution fell through to LoggerSuccess anyway
; -- defeating the very LoggerStart/LoggerSuccess pairing asserted above,
; since the log would claim success even when registration actually failed.
_AGRG_HotkeyFailuresAreCaughtAndLogged() {
	Seg := _DriverFuncBody("_RegisterAltGrShortcutsHotkeys")
	Assert(Seg != "", "_RegisterAltGrShortcutsHotkeys() declaration must exist in altgr.ahk")

	for _, Combo in ["SC138 & SC038", "SC138 & SC03A"] {
		CallNeedle := 'Hotkey("' . Combo . '"'
		CallPos := InStr(Seg, CallNeedle)
		Assert(CallPos > 0, "_RegisterAltGrShortcutsHotkeys must still register " . Combo)

		Window := SubStr(Seg, CallPos, 250)
		Assert(InStr(Window, "catch") > 0,
			"_RegisterAltGrShortcutsHotkeys: the Hotkey(" . Combo . ") call must have a catch clause -- a bare try silently swallows a registration failure and still reaches LoggerSuccess")
		Assert(InStr(Window, "LoggerError") > 0,
			"_RegisterAltGrShortcutsHotkeys: a failed Hotkey(" . Combo . ") registration must LoggerError so it is diagnosable")

		SuccessPos := InStr(Seg, "LoggerSuccess")
		CatchReturnPos := InStr(Window, "return")
		Assert(CatchReturnPos > 0 and (CallPos + CatchReturnPos) < SuccessPos,
			"_RegisterAltGrShortcutsHotkeys: the catch clause for " . Combo . " must return BEFORE LoggerSuccess -- otherwise a failed registration would still log success")
	}
}
Test("Shortcuts/altgr: failed Hotkey() registrations are caught, logged, and skip LoggerSuccess (altgr-hotkey-registration-swallowed)",
	_AGRG_HotkeyFailuresAreCaughtAndLogged)
