; tests/meta/test_tray_menu_cleared_before_onboarding.ahk

; ==============================================================================
; MODULE: Tray Menu Cleared Before Onboarding Meta Test
; DESCRIPTION:
; Regression guard for AHK-21: the AHK stock tray menu (Pause/Suspend/Reload/
; Exit/Edit Script) remained live throughout the first-run onboarding wizard
; because A_TrayMenu.Delete() was called at ErgoptiPlus.ahk:615, well after
; Onboarding_Run() at line 272. On a fresh install (no config.toml)
; Onboarding_Run blocks in a message-pump loop until the wizard commits or is
; dismissed — meaning the stock AHK items were available for the entire wizard
; duration. A user could Reload (reopening the identical config-less wizard) or
; Exit (duplicating the wizard dismiss) through the stock menu, bypassing the
; driver's own shutdown handlers.
;
; The fix moves A_TrayMenu.Delete() to BEFORE Onboarding_Run() so stock items
; are gone from the first frame of the first-run wizard. On a normal (non-first-
; run) boot Onboarding_Run() is a no-op, so the move is safe for all paths.
;
; This test asserts (source introspection on the full ErgoptiPlus.ahk concat):
;   A_TrayMenu.Delete() must appear at a LOWER source offset than
;   Onboarding_Run() — encoding the ordering requirement that the stock menu is
;   cleared before the blocking first-run wizard can display.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================================
; ===================================================================
; ======= 1/ Test implementation ====================================
; ===================================================================
; ===================================================================

_TTMCBO_CheckTrayDeleteBeforeOnboarding() {
	; Read ErgoptiPlus.ahk directly from the driver source tree (sibling of tests/)
	EntryPath := A_ScriptDir . "\..\ErgoptiPlus.ahk"
	Source := ""
	try Source := FileRead(EntryPath, "UTF-8")
	Assert(Source != "", "ErgoptiPlus.ahk must be readable at " . EntryPath)

	DeletePos    := InStr(Source, "A_TrayMenu.Delete()")
	OnboardingPos := InStr(Source, "Onboarding_Run()")

	Assert(DeletePos > 0,
		"AHK-21: A_TrayMenu.Delete() must exist in ErgoptiPlus.ahk — it clears the stock AHK tray items so they are not available during the first-run onboarding wizard")
	Assert(OnboardingPos > 0,
		"AHK-21: Onboarding_Run() must exist in ErgoptiPlus.ahk")
	Assert(DeletePos < OnboardingPos,
		"AHK-21: A_TrayMenu.Delete() must appear BEFORE Onboarding_Run() in ErgoptiPlus.ahk — on first run Onboarding_Run blocks until the wizard commits, so the stock Pause/Suspend/Reload/Exit items must be removed before the wizard can be shown")
}


Test("meta ahk-21: A_TrayMenu.Delete() precedes Onboarding_Run() in ErgoptiPlus.ahk so stock tray items are not live during onboarding",
	_TTMCBO_CheckTrayDeleteBeforeOnboarding)
