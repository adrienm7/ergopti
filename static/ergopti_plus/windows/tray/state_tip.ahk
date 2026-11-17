; tray/state_tip.ahk

; ==============================================================================
; MODULE: Tray Icon State Tip
; DESCRIPTION:
; The tray icon's tooltip is also its accessible name: Narrator, NVDA and JAWS
; read it when the notification area takes the focus. It used to be the
; script's file name and the pause was told by the icon alone, so a screen
; reader user could not tell a paused driver from a running one. It now says
; « Ergopti+ » or « Ergopti+ (paused) » in the active language, as the macOS
; menu-bar item and the Linux indicator do. Definitions only.
; ==============================================================================

#Requires AutoHotkey v2.0

; The translated tray text for a pause state.
; @param Suspended {Boolean} Whether the driver is paused.
; @returns {String}
TrayStateTipText(Suspended) {
	return t(Suspended ? "accessibility.tray_tip_paused" : "accessibility.tray_tip")
}

; Publishes the tray text of a pause state. While the navigation layer shows
; its own name there, the text becomes the one the layer restores instead.
; @param Suspended {Boolean} Whether the driver is paused.
; @param SetFn {Func|Integer} Replaces TrayMenuSetTooltip (tests only).
; @param RebaseFn {Func|Integer} Replaces NavigationLayerIndicatorRebase (tests only).
; @returns {Boolean} Whether the text was published or handed to the layer.
TrayPublishStateTip(Suspended, SetFn := 0, RebaseFn := 0) {
	Text := TrayStateTipText(Suspended)
	Rebase := IsObject(RebaseFn) ? RebaseFn : NavigationLayerIndicatorRebase
	if Rebase.Call(Text)
		return true
	Set := IsObject(SetFn) ? SetFn : TrayMenuSetTooltip
	if Set.Call(Text) == true
		return true
	try LoggerWarn("TrayMenu", "The tray state text '{1}' was not published.", Text)
	return false
}
