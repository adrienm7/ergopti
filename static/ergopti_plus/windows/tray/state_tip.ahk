; tray/state_tip.ahk

; ==============================================================================
; MODULE: Tray Icon State Tip
; DESCRIPTION:
; The tray icon's tooltip is also its accessible name: Narrator, NVDA and JAWS
; read it when the notification area takes the focus. It used to be the
; script's file name and the pause was told by the icon alone, so a screen
; reader user could not tell a paused driver from a running one. It now says
; « Ergopti+ » or « Ergopti+ (paused) » in the active language, as the macOS
; menu-bar item and the Linux indicator do. The icon is named before it is
; shown (TrayRevealNamed). Definitions only.
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

; Names the tray icon, then shows it. Until its tooltip is set, AutoHotkey
; names the icon by the script's file name, which is what a screen reader
; announced for the whole first-run wizard and the start of every boot.
; @param Text {String} The translated tray text.
; @param RevealFn {Func} Shows the icon; ErgoptiPlus.ahk owns the one reveal.
; @param SetFn {Func|Integer} Replaces TrayMenuSetTooltip (tests only).
; @returns {Boolean} Whether the name was published before the icon appeared.
; @throws {ValueError} When there is no name to give or nothing to reveal with.
TrayRevealNamed(Text, RevealFn, SetFn := 0) {
	if Type(Text) != "String" || Text == ""
		throw ValueError("The tray icon needs its accessible name before it is shown")
	if !HasMethod(RevealFn, "Call")
		throw TypeError("Revealing the tray icon requires its reveal owner")
	Set := IsObject(SetFn) ? SetFn : TrayMenuSetTooltip
	Named := Set.Call(Text) == true
	; The icon is the driver's only control surface: it still appears unnamed.
	if !Named
		try LoggerError("TrayMenu", "The tray icon is shown without its name '{1}'.", Text)
	RevealFn.Call()
	return Named
}
