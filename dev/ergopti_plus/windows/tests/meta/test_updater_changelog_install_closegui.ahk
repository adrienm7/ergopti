; tests/meta/test_updater_changelog_install_closegui.ahk

; ==============================================================================
; MODULE: Updater Changelog Install-Button CloseGui Meta Test
; DESCRIPTION:
; Regression guard for finding F31: InstallSelected (the changelog window's
; "Install this version" button handler, defined inside
; _Updater_BuildChangelogGui) was the sole close path in
; lib/updater/changelog.ahk that bypassed the _Updater_CloseGui helper --
; every other close path (BtnSwitch, G's Close/Escape events) routes through
; it. _Updater_CloseGui closes the WebView2 Controller before destroying the
; Gui; a bare G.Destroy() skips that step.
;
; SCOPE: source introspection of lib/updater/changelog.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ================================================================
; ================================================================
; ======= 1/ InstallSelected closes via _Updater_CloseGui ========
; ================================================================
; ================================================================

_UCIG_CheckInstallSelectedUsesCloseGui() {
	Body := _DriverFuncBody("_Updater_BuildChangelogGui")
	Assert(Body != "", "_Updater_BuildChangelogGui must exist in lib/updater/changelog.ahk")

	IdxAssign := InStr(Body, "InstallSelected := ")
	Assert(IdxAssign > 0, "_Updater_BuildChangelogGui must still define InstallSelected")

	; Bound the InstallSelected closure by the next statement (BtnSwitch.OnEvent)
	; so a coincidental _Updater_CloseGui/G.Destroy() elsewhere in the
	; surrounding Gui-builder cannot produce a false pass/fail.
	IdxNext := InStr(Body, "BtnSwitch.OnEvent(", , IdxAssign)
	Assert(IdxNext > IdxAssign, "could not bound the InstallSelected closure for inspection")
	InstallSelectedBody := SubStr(Body, IdxAssign, IdxNext - IdxAssign)

	Assert(InStr(InstallSelectedBody, "_Updater_CloseGui(G)") > 0,
		"InstallSelected must close the window via _Updater_CloseGui(G), matching every other close path in lib/updater/changelog.ahk -- a bare G.Destroy() skips closing the WebView2 Controller first (updater-changelog-install-bare-destroy)")
	Assert(InStr(InstallSelectedBody, "G.Destroy()") = 0,
		"InstallSelected must not call the bare G.Destroy() -- it bypasses the _Updater_CloseGui helper that closes the WebView2 Controller before destroying the Gui (updater-changelog-install-bare-destroy)")
}
Test("updater changelog: InstallSelected closes via _Updater_CloseGui, not a bare G.Destroy() (updater-changelog-install-bare-destroy)",
	_UCIG_CheckInstallSelectedUsesCloseGui)
