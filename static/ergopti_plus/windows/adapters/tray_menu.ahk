; adapters/tray_menu.ahk

; ==============================================================================
; MODULE: TrayMenu Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the TrayMenu port contract defined in
; static/ergopti_plus/_shared/core/ports/TrayMenu.spec.js. Wraps the AHK v2 A_TrayMenu
; and TraySetIcon APIs behind the four canonical functions (TrayMenuSetIcon,
; TrayMenuSetMenu, TrayMenuSetTooltip, TrayMenuDestroy) so domain modules can
; manage the Windows tray icon without coupling to AHK-specific APIs.
;
; NAMING CONVENTION:
; Port method → AHK name mapping:
;   setIcon(opts)      → TrayMenuSetIcon(Opts)
;   setMenu(items)     → TrayMenuSetMenu(Items)
;   setTooltip(text)   → TrayMenuSetTooltip(Text)
;   destroy()          → TrayMenuDestroy()
;
; MENU ITEM SHAPE:
; Each entry in the Items array passed to TrayMenuSetMenu must be a Map with:
;   { "title", "fn" [, "checked" = false] [, "disabled" = false] [, "separator" = false] }
; ==============================================================================




; ===================================================
; ===================================================
; ======= 1/ Adapter Methods ========================
; ===================================================
; ===================================================

; Sets the tray icon image and/or tooltip.
; @param Opts {Map|0} { image?: path_string, title?: label_string }
;               image  {String} Path to an ICO or PNG file.
;               title  {String} Text label shown as the tooltip text (via TrayMenuSetTooltip).
TrayMenuSetIcon(Opts) {
	if !(Opts is Map)
		return
	if Opts.Has("image") and Opts["image"] != "" {
		try TraySetIcon(Opts["image"])
	}
	if Opts.Has("title") and Opts["title"] != "" {
		TrayMenuSetTooltip(Opts["title"])
	}
}

; Replaces all items in the tray context menu.
; Clears the existing menu and rebuilds it from the Items array.
; @param Items {Array} Array of Maps: { title, fn [, checked, disabled, separator] }
TrayMenuSetMenu(Items) {
	; Stale menu-item IDs left in the dispatcher's tracking Maps after a raw
	; Delete() can be recycled by the next Add() and fire the wrong callback --
	; the same AHK 2.0 click-drop class RegisterMenuItem below exists to guard
	; against. Reset the dispatcher's bookkeeping before rebuilding, mirroring
	; _Updater_RebuildMenu (modules/updater/core.ahk).
	try MenuDispatcher_Reset()
	try A_TrayMenu.Delete()
	if !(Items is Array)
		return
	for Item in Items {
		if !(Item is Map)
			continue
		IsSep := Item.Has("separator") and Item["separator"]
		if IsSep {
			; A separator is a zero-argument Add(). AddStandard() instead appends
			; the entire default AHK script-control menu (Exit / Reload / Suspend),
			; which the product UI deliberately hides — never use it here.
			try A_TrayMenu.Add()
			continue
		}
		ItemTitle := Item.Has("title") ? Item["title"] : ""
		ItemFn    := Item.Has("fn")    ? Item["fn"]    : 0
		if ItemTitle = "" or ItemFn = 0
			continue
		; Route actionable items through RegisterMenuItem so they participate in
		; the menu_dispatcher WM_COMMAND retry path. Raw Menu.Add does not, so AHK
		; 2.0's intermittent dispatch drop would silently lose ~1 click in 3.
		try RegisterMenuItem(A_TrayMenu, ItemTitle, ItemFn)
		if Item.Has("checked") and Item["checked"]
			try A_TrayMenu.Check(ItemTitle)
		if Item.Has("disabled") and Item["disabled"]
			try A_TrayMenu.Disable(ItemTitle)
	}
}

; Sets the tooltip shown when the user hovers over the tray icon.
; @param Text {String} Tooltip text (Windows clips at ~127 characters).
TrayMenuSetTooltip(Text) {
	try {
		A_IconTip := Text
	} catch as Err {
		try LoggerWarn("TrayMenu", "TrayMenuSetTooltip failed: {1}.", Err.Message)
	}
}

; Resets the tray icon and menu to AHK defaults.
; Calling this before ExitApp prevents orphaned tray icons.
TrayMenuDestroy() {
	try {
		A_TrayMenu.Delete()
		TraySetIcon()
		A_IconTip := ""
	}
}

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/test_adapter_compliance_new.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_TRAY_MENU := Map(
    "setIcon",    TrayMenuSetIcon,
    "setMenu",    TrayMenuSetMenu,
    "setTooltip", TrayMenuSetTooltip,
    "destroy",    TrayMenuDestroy,
)
