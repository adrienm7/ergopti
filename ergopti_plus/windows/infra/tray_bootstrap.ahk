; infra/tray_bootstrap.ahk

; ==============================================================================
; MODULE: Safe Cold-Start Tray Bootstrap
; DESCRIPTION:
; Publishes native lifecycle commands before the icon is exposed. First-run
; setup keeps an inert bootstrap under its own wizard owner. The tray-root
; coordinator replaces either root atomically after initialization. Definitions
; only, so startup boundaries and unit tests can use the same ownership.
; ==============================================================================

#Requires AutoHotkey v2.0

_TrayBootstrapNoOp(*) {
	return 0
}

/** Publishes real native lifecycle rows before exposing the tray icon. */
_InstallNativeStartupTray(RequestFn, MenuObj := 0, RegisterFn := 0) {
	if !HasMethod(RequestFn, "Call")
		throw TypeError("Native startup tray requires a command owner")
	if !IsObject(MenuObj)
		MenuObj := A_TrayMenu
	Register := HasMethod(RegisterFn, "Call") ? RegisterFn : RegisterMenuItem
	; Locale cache misses may read disk; finish them before atomic publication.
	Rows := []
	for Id in ["suspend", "reload", "quit"]
		Rows.Push({Id: Id, Label: t("menu.global." . Id), Callback: MenuStartupSafeCommand(RequestFn.Bind(Id))})
	PreviousCritical := Critical("On")
	try {
		MenuDispatcher_BeginReplacement()
		MenuObj.Delete()
		for Row in Rows {
			if Register.Call(MenuObj, Row.Label, Row.Callback) != 1
				throw Error("Native startup command registration failed: " . Row.Id)
		}
		if !HasMethod(RegisterFn, "Call")
			MenuDispatcher_PruneMenu(MenuObj)
		return true
	} finally Critical(PreviousCritical)
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
