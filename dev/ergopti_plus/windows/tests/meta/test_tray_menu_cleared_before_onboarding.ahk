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
; The fix invokes the safe bootstrap publisher BEFORE Onboarding_Run() so stock
; items are gone and one inert replacement row exists from the first frame of
; the first-run wizard. On a normal (non-first-run) boot Onboarding_Run() is a
; no-op, so the same publication is safe for all paths.
;
; This test asserts (source introspection on the full ErgoptiPlus.ahk concat):
;   _InstallSafeBootstrapTray() must appear at a LOWER source offset than
;   Onboarding_Run(), and that helper must itself own Delete + Add + Disable.
;   Looking for an arbitrary Delete() in the entrypoint is a false green: the
;   updater-recovery path has an unrelated early Delete which normal boot never
;   executes.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================================
; ===================================================================
; ======= 1/ Test implementation ====================================
; ===================================================================
; ===================================================================

_TTMCBO_CheckTrayDeleteBeforeOnboarding() {
	Source := _DriverSourceNoComments()
	Assert(Source != "", "the concatenated production source must be readable")
	BootstrapPos := InStr(Source, "_InstallSafeBootstrapTray()")
	OnboardingPos := InStr(Source, "Onboarding_Run()", , Max(1, BootstrapPos))
	Assert(BootstrapPos > 0 && OnboardingPos > BootstrapPos,
		"AHK-21: the safe bootstrap publisher must run before the blocking onboarding wizard")

	Bootstrap := _DriverFuncBody("_InstallSafeBootstrapTray")
	Assert(Bootstrap != "", "the safe bootstrap helper must remain source-visible")
	Assert(InStr(Bootstrap, "MenuObj.Delete()") > 0
		&& InStr(Bootstrap, "MenuObj.Add(") > 0
		&& InStr(Bootstrap, "MenuObj.Disable(") > 0,
		"AHK-21: normal boot must replace stock actions with one inert row, not rely on an unrelated recovery-only Delete")
}


Test("meta ahk-21: safe bootstrap publication precedes Onboarding_Run so stock tray items are not live during onboarding",
	_TTMCBO_CheckTrayDeleteBeforeOnboarding)
