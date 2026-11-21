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
; shown (TrayRevealNamed).
;
; Each pause state draws its own logo file (TrayApplyStateIcon). A missing file
; used to keep whatever icon was there, so a damaged install showed the running
; logo on a paused driver without a word (TRAY-05). It now logs one error per
; missing file, draws the Windows warning sign, and the tray text says the file
; is missing. Definitions only.
; ==============================================================================

#Requires AutoHotkey v2.0

; The pause states whose logo file was missing when last drawn: 1 for paused,
; 0 for running. A function-owned Map because boot.ahk draws the first icon
; before this file's include position would have run an initializer.
; @returns {Map}
_TrayMissingStateIcons() {
	static Missing := Map()
	return Missing
}

; The translated tray text for a pause state, which says when its logo file is
; missing, since the warning sign drawn instead does not say which state it is.
; @param Suspended {Boolean} Whether the driver is paused.
; @returns {String}
TrayStateTipText(Suspended) {
	if _TrayMissingStateIcons().Has(Suspended ? 1 : 0)
		return t(Suspended ? "accessibility.tray_tip_paused_icon_missing" : "accessibility.tray_tip_icon_missing")
	return t(Suspended ? "accessibility.tray_tip_paused" : "accessibility.tray_tip")
}

; Draws the logo of a pause state from its own file. A missing file is never
; replaced by the other state's logo: it is logged once, and the Windows
; warning sign (user32.dll icon resource 101) is drawn until the file returns.
; The paused icon is frozen so AutoHotkey does not swap in its own suspended one.
; @param Suspended {Boolean} Whether the driver is paused.
; @param Path {String} The state's logo file.
; @param ExistFn {Func|Integer} Replaces FileExist (tests only).
; @param SetIconFn {Func|Integer} Replaces TraySetIcon (tests only).
; @param LogFn {Func|Integer} Replaces the error log of a missing file (tests only).
; @returns {Boolean} Whether the state's own logo is drawn.
TrayApplyStateIcon(Suspended, Path, ExistFn := 0, SetIconFn := 0, LogFn := 0) {
	static Logged := Map()
	Exists := IsObject(ExistFn) ? ExistFn : FileExist
	SetIcon := IsObject(SetIconFn) ? SetIconFn : TraySetIcon
	State := Suspended ? 1 : 0
	if Type(Path) == "String" && Path != "" && Exists.Call(Path) != "" {
		if Suspended
			SetIcon.Call(Path, , true)
		else
			SetIcon.Call(Path)
		Missing := _TrayMissingStateIcons()
		if Missing.Has(State)
			Missing.Delete(State)
		return true
	}
	_TrayMissingStateIcons()[State] := Path
	if !Logged.Has(Path) {
		Logged[Path] := true
		LogMissing := IsObject(LogFn) ? LogFn : _TrayLogMissingIcon
		LogMissing.Call(Path)
	}
	try {
		if Suspended
			SetIcon.Call("user32.dll", -101, true)
		else
			SetIcon.Call("user32.dll", -101)
	} catch as Err {
		try LoggerError("TrayMenu", "The warning sign for a missing tray icon could not be drawn: {1}.", Err.Message)
	}
	return false
}

; Logs a missing tray logo file, once per file (TrayApplyStateIcon).
; @param Path {String} The missing file.
_TrayLogMissingIcon(Path) {
	try LoggerError("TrayMenu", "Tray icon file '{1}' is missing; the warning sign is drawn instead. Reinstall Ergopti+.", Path)
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
