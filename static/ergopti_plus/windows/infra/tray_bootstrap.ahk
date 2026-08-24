; infra/tray_bootstrap.ahk

; ==============================================================================
; MODULE: Safe Cold-Start Tray Bootstrap
; DESCRIPTION:
; Publishes one inert status row immediately after stock tray actions are
; removed. The full tray-root coordinator later replaces it atomically with a
; complete tree. Kept definitions-only so the first-run and post-i18n boot
; boundaries can call the same behavior and unit tests can inject a fake menu.
; ==============================================================================

#Requires AutoHotkey v2.0

_TrayBootstrapNoOp(*) {
	return 0
}

_InstallSafeBootstrapTray(Label := "ErgoptiPlus — Starting…", MenuObj := 0) {
	if !(Label is String) or Label == ""
		throw ValueError("tray bootstrap label must be a non-empty string")
	if !IsObject(MenuObj)
		MenuObj := A_TrayMenu
	PreviousCritical := Critical("On")
	try {
		; Own retirement and replacement in one uninterruptible AHK transaction.
		; A caller-side Delete followed by this helper left a real click/timer seam
		; in which Windows could display an empty root.
		MenuObj.Delete()
		MenuObj.Add(Label, _TrayBootstrapNoOp)
		MenuObj.Disable(Label)
		return true
	} finally Critical(PreviousCritical)
}
