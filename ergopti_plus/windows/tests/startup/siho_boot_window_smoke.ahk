; static/ergopti_plus/windows/tests/startup/siho_boot_window_smoke.ahk

; ============================================================================
; MODULE: Suppressive-Hook Boot Window Harness
; DESCRIPTION:
; Reproduces the exact window in which a remapped key can be pressed while the
; driver is still booting: AutoHotkey registers every static hotkey when the
; script is LOADED, so a hotkey thread can call into a module whose
; auto-execute initialisation has not run yet.
;
; The include below sits after the first probe on purpose. Function definitions
; are hoisted, so SIHO_Count() is callable, but `global _SIHO_Owners := Map()`
; has not executed — which is precisely the state ErgoptiPlus.ahk is in between
; its first line and infra/suppressive_inputhook_ownership.ahk's include
; position a thousand lines later.
;
; Before the fix this harness died with "This global variable has not been
; assigned a value", the same UnsetError that killed the real driver through
; _DigitRowDown -> _EmitReachedScreen -> SIHO_HasActive
; (siho-count-before-include).
;
; EXIT CODES: 0 pass, 10 non-zero count in the boot window, 11 active hooks
; reported in the boot window, 12 the registry still did not exist after the
; module ran, 13 the initialised module disagreed with the boot-window answer.
; They start at 10 so no assertion can be confused with AutoHotkey's own exit 1
; (fail) or 2 (load or runtime error) — the pre-fix UnsetError is exactly a 2.
; ============================================================================

#Requires AutoHotkey v2.0+
#SingleInstance Off
#NoTrayIcon
SetWorkingDir(A_ScriptDir)
#Warn All, StdOut
#Warn VarUnset, Off

; The module logs two rollback refusals through the central logger, which this
; harness deliberately does not load: pulling in the logger would drag the boot
; graph whose absence is the whole point of the fixture. AHK v2 resolves a call
; to an undefined function as a variable read, so without these the harness
; emits "This local variable appears to never be assigned a value" for every
; LoggerError call site under #Warn All. Neither path is exercised here; the
; stub exists so the harness stays quiet and self-contained.
LoggerError(Component, Message, Args*) {
	return true
}

; ---- The boot window: the registry does not exist yet. ----
if (SIHO_Count() != 0)
	ExitApp(10)
if SIHO_HasActive()
	ExitApp(11)

#Include ../../infra/suppressive_inputhook_ownership.ahk

; ---- The module has now run: the same answers, from real state. ----
if !IsSet(_SIHO_Owners)
	ExitApp(12)
if (SIHO_Count() != 0 || SIHO_HasActive())
	ExitApp(13)
ExitApp(0)
