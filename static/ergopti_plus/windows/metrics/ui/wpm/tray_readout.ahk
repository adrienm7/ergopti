; metrics/ui/wpm/tray_readout.ahk

; ==============================================================================
; MODULE: WPM Notification-Area Readout (Windows)
; DESCRIPTION:
; The live typing speed in the notification area, beside the Ergopti+ icon:
; the Windows counterpart of the macOS menu bar readout and of
; linux/metrics/ui/wpm/tray_readout.lua. A second notification icon appears while the
; user types, shows the number on the source's colour, and hides when typing
; stops.
;
; FEATURES & RATIONALE:
; 1. An icon, not a label: the Windows notification area shows icons only, so
;    the number is painted into the icon, as on Linux.
; 2. The same decisions as the other two drivers, from the same canon
;    (_shared/metrics/data/wpm_widget/constants.toml [menubar]): shown while the
;    speed is above zero, a preview is up or a source still colours it; the
;    source colour at the canon's background_alpha, the neutral fill otherwise.
; 3. One icon, added once and then hidden or shown, so it keeps its place.
;    Explorer forgets it when it restarts; "TaskbarCreated" re-adds it.
; 4. The keystrokes are the floating widget's ring (display.ahk), which
;    fills while either readout is on; the readout adds no keyboard hook.
; 5. Windows decides whether a new icon sits in the visible area or in the
;    overflow; the user pins it from Settings > Personalisation > Taskbar.
; ==============================================================================

#Requires AutoHotkey v2.0






; ===============================
; ===============================
; ======= 1/ Module state =======
; ===============================
; ===============================

class WPMTrayReadout {
	; The icon's id beside the script window; AutoHotkey's own icon is 1028.
	static ICON_ID := 0x4550
	; Icon geometry as fractions of the shell's small-icon side, the ratios of
	; the Linux 44 px icon (font 24, inset 3, radius 8).
	static FONT_RATIO := 24 / 44
	static INSET_RATIO := 3 / 44
	static RADIUS_RATIO := 8 / 44

	; The user's choices. Placeholders only: WPMTrayReadout_LoadConfig()
	; replaces them at boot with the configured value or the manifest default.
	static running := false
	static use_colors := false

	; Native presentation.
	static _timer := 0
	static _added := false
	static _shown := false
	static _hicon := 0
	static _last_key := ""
	static _taskbar_message := 0
}





; ================================
; ================================
; ======= 2/ Configuration =======
; ================================
; ================================

; Reads the two [metrics] readout booleans. An absent key takes its manifest
; default, through the same reader as the floating widget's booleans.
; @param Cache {Map} The boot configuration cache.
WPMTrayReadout_LoadConfig(Cache) {
	WPMTrayReadout.running := _WPMWidget_ConfigBoolean(
		IniCacheGet(Cache, "metrics", ConfigLeaf.WPM_MENUBAR_VISIBLE), ConfigLeaf.WPM_MENUBAR_VISIBLE)
	WPMTrayReadout.use_colors := _WPMWidget_ConfigBoolean(
		IniCacheGet(Cache, "metrics", ConfigLeaf.WPM_MENUBAR_COLORS), ConfigLeaf.WPM_MENUBAR_COLORS)
	LoggerDone("WPMTrayReadout", "Config loaded — visible={1}, colors={2}.",
		WPMTrayReadout.running, WPMTrayReadout.use_colors)
}

_WPMTrayReadout_PublishVisible(Target) {
	WPMTrayReadout.running := Target
}

_WPMTrayReadout_PublishColors(Target) {
	WPMTrayReadout.use_colors := Target
	WPMTrayReadout._last_key := ""
}

_WPMTrayReadout_BuildToggle(Key, Current, PublishFn) {
	Target := !Current
	return { updates: [{ Section: "metrics", Key: Key, Value: Target }], publish: PublishFn.Bind(Target) }
}

; The Metrics menu row « WPM in menu bar »: persists the flipped choice, then
; starts or stops the icon.
; @param WriterFn, NotifyFn {Func|0} Configuration gateway seams.
; @returns {Boolean} True once the choice is durable and applied.
WPMTrayReadout_Toggle(WriterFn := 0, NotifyFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return WPMTrayReadout_Toggle(WriterFn, NotifyFn)
		finally Critical(InheritedCritical)
	}
	BuildFn := () => _WPMTrayReadout_BuildToggle(ConfigLeaf.WPM_MENUBAR_VISIBLE,
		WPMTrayReadout.running, _WPMTrayReadout_PublishVisible)
	if !_WPMWidget_SaveBuilt(BuildFn, "notification-area readout visibility", WriterFn, NotifyFn)
		return false
	return WPMTrayReadout.running ? WPMTrayReadout_Start() : WPMTrayReadout_Stop()
}

; The Metrics menu row « Colour by input source » under the readout.
; @returns {Boolean} True once the choice is durable.
WPMTrayReadout_ToggleColors(WriterFn := 0, NotifyFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return WPMTrayReadout_ToggleColors(WriterFn, NotifyFn)
		finally Critical(InheritedCritical)
	}
	BuildFn := () => _WPMTrayReadout_BuildToggle(ConfigLeaf.WPM_MENUBAR_COLORS,
		WPMTrayReadout.use_colors, _WPMTrayReadout_PublishColors)
	return _WPMWidget_SaveBuilt(BuildFn, "notification-area readout colours", WriterFn, NotifyFn)
}





; ============================
; ============================
; ======= 3/ Lifecycle =======
; ============================
; ============================

; Arms the refresh. Idempotent; the icon itself is added on the first frame.
; @returns {Boolean} True when the readout is running after this call.
WPMTrayReadout_Start() {
	if WPMTrayReadout._timer
		return true
	if WPMWidgetConst.MENUBAR_TICK_MS <= 0 {
		LoggerError("WPMTrayReadout", "The WPM canon was not loaded — the notification-area readout stays off.")
		return false
	}
	if !WPMTrayReadout._taskbar_message {
		WPMTrayReadout._taskbar_message := NotifyIcon_TaskbarCreatedMessage()
		if WPMTrayReadout._taskbar_message
			OnMessage(WPMTrayReadout._taskbar_message, _WPMTrayReadout_OnTaskbarCreated)
		else
			LoggerWarn("WPMTrayReadout", "TaskbarCreated could not be registered; an Explorer restart drops the readout until the next toggle.")
	}
	WPMTrayReadout._timer := TimerEvery(WPMWidgetConst.MENUBAR_TICK_MS / 1000, WPMTrayReadout_Tick)
	LoggerInfo("WPMTrayReadout", "WPM notification-area readout started.")
	return true
}

; Restores the persisted choice at boot.
WPMTrayReadout_BootStart() {
	if WPMTrayReadout.running
		WPMTrayReadout_Start()
}

; Stops the refresh and removes the icon.
; @returns {Boolean} True once the timer is cancelled and the icon is gone.
WPMTrayReadout_Stop() {
	if WPMTrayReadout._timer {
		if !TimerCancel(WPMTrayReadout._timer) {
			LoggerError("WPMTrayReadout", "The readout refresh could not be cancelled.")
			return false
		}
		WPMTrayReadout._timer := 0
	}
	if !_WPMTrayReadout_Remove()
		return false
	LoggerInfo("WPMTrayReadout", "WPM notification-area readout stopped.")
	return true
}

; Driver exit: the shell keeps a dead process's icon until the pointer crosses it.
WPMTrayReadout_Shutdown() {
	return WPMTrayReadout_Stop()
}

_WPMTrayReadout_Remove() {
	if WPMTrayReadout._added {
		if !NotifyIcon_Delete(A_ScriptHwnd, WPMTrayReadout.ICON_ID) {
			LoggerError("WPMTrayReadout", "The shell refused to remove the readout icon.")
			return false
		}
		WPMTrayReadout._added := false
	}
	WPMTrayReadout._shown := false
	WPMTrayReadout._last_key := ""
	if !NotifyIcon_DestroyIcon(WPMTrayReadout._hicon)
		LoggerWarn("WPMTrayReadout", "The previous readout icon handle could not be released.")
	WPMTrayReadout._hicon := 0
	return true
}

; The pause transition owner: the refresh does not run while paused, so the
; icon is hidden here rather than left showing the last number.
; @returns {Boolean} True once the icon is hidden or was not shown.
WPMTrayReadout_HideForPause() {
	if !WPMTrayReadout._shown
		return true
	if !NotifyIcon_SetHidden(A_ScriptHwnd, WPMTrayReadout.ICON_ID, true)
		return false
	WPMTrayReadout._shown := false
	WPMTrayReadout._last_key := ""
	return true
}

; Explorer rebuilt the notification area without our icon: add it again on
; the next frame.
_WPMTrayReadout_OnTaskbarCreated(*) {
	WPMTrayReadout._added := false
	WPMTrayReadout._shown := false
	WPMTrayReadout._last_key := ""
}





; =========================
; =========================
; ======= 4/ Frames =======
; =========================
; =========================

; What the readout shows now: Model.menubar_frame and Model.menubar_visible on
; macOS and Linux, from the widget's ring and source watermarks.
; @returns {Map} visible, number, fill (hex without '#'), alpha (0..1).
WPMTrayReadout_Frame() {
	Wpm := WPMWidget_Calc()["wpm"]
	Sources := WPMWidget_ActiveSources()
	Coloured := Sources["has_hs"] || Sources["has_ai"] || Sources["has_ac"]
	Visible := Wpm > 0 || Coloured || _WPMWidget_TooltipUp()
	UseSource := WPMTrayReadout.use_colors && Coloured
	return Map("visible", Visible, "number", String(Wpm),
		"fill", UseSource ? WPMWidget_ResolveBgColor(false, Sources["has_hs"], Sources["has_ai"],
			Sources["has_ac"], true) : WPMWidgetConst.MENUBAR_NEUTRAL_BG,
		"alpha", UseSource ? WPMWidgetConst.MENUBAR_ALPHA : 1)
}

; The refresh: hides the icon while nothing is typed, the driver is paused or
; metrics are off, and repaints it only when the number or colour changed.
WPMTrayReadout_Tick() {
	if !WPMTrayReadout.running
		return
	Frame := (A_IsSuspended || !MetricsShortcuts.enabled) ? Map("visible", false) : WPMTrayReadout_Frame()
	if !Frame["visible"] {
		if WPMTrayReadout._shown {
			if !NotifyIcon_SetHidden(A_ScriptHwnd, WPMTrayReadout.ICON_ID, true)
				return
			WPMTrayReadout._shown := false
		}
		WPMTrayReadout._last_key := ""
		return
	}
	Key := Frame["number"] . "|" . Frame["fill"] . "|" . Frame["alpha"]
	if (Key == WPMTrayReadout._last_key && WPMTrayReadout._shown)
		return
	if !WPMWidget_EnsureGdip()
		return
	Size := SysGet(49)  ; SM_CXSMICON: the side the shell draws notification icons at
	try HIcon := NotifyIcon_PaintNumber(Size, Frame["number"],
		_WPMWidget_Argb(Frame["fill"], Frame["alpha"]), WPMWidget_HexToRgbInt(WPMWidgetConst.MENUBAR_TEXT),
		Round(Size * WPMTrayReadout.FONT_RATIO), Round(Size * WPMTrayReadout.INSET_RATIO),
		Round(Size * WPMTrayReadout.RADIUS_RATIO))
	catch as Err {
		LoggerError("WPMTrayReadout", "The readout icon could not be painted: {1}.", Err.Message)
		return
	}
	Tip := Frame["number"] . " " . t("menu.metrics.wpm_unit")
	if !NotifyIcon_Publish(A_ScriptHwnd, WPMTrayReadout.ICON_ID, HIcon, Tip, false, !WPMTrayReadout._added) {
		NotifyIcon_DestroyIcon(HIcon)
		; A refused NIM_ADD may mean Explorer is not up yet; a later tick retries.
		return
	}
	Previous := WPMTrayReadout._hicon
	WPMTrayReadout._hicon := HIcon
	WPMTrayReadout._added := true
	WPMTrayReadout._shown := true
	WPMTrayReadout._last_key := Key
	if !NotifyIcon_DestroyIcon(Previous)
		LoggerWarn("WPMTrayReadout", "The previous readout icon handle could not be released.")
}
