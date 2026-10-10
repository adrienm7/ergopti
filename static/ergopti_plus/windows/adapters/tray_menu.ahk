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
if !TrayMenuFrameNative("current")
	throw Error("The native menu adapter could not retain its intrinsic cohort")

TrayMenuSetIcon(Opts) {
	if !(Opts is Map)
		return
	if Opts.Has("image") and Opts["image"] != "" {
		try TraySetIcon(Opts["image"])
		catch as Err
			try LoggerError("TrayMenu", "Tray icon '{1}' could not be applied: {2}.", Opts["image"], Err.Message)
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
		; A refused row used to vanish from the menu with nothing in the log.
		try {
			RegisterMenuItem(A_TrayMenu, ItemTitle, ItemFn)
			if Item.Has("checked") and Item["checked"]
				A_TrayMenu.Check(ItemTitle)
			if Item.Has("disabled") and Item["disabled"]
				A_TrayMenu.Disable(ItemTitle)
		} catch as Err {
			try LoggerError("TrayMenu", "Tray menu row '{1}' could not be published: {2}.", ItemTitle, Err.Message)
		}
	}
}

; Sets the tooltip shown when the user hovers over the tray icon.
; @param Text {String} Tooltip text (Windows clips at ~127 characters).
; @returns {Boolean} Whether the native tooltip assignment succeeded.
TrayMenuSetTooltip(Text) {
	try {
		A_IconTip := Text
		return true
	} catch as Err {
		try LoggerWarn("TrayMenu", "TrayMenuSetTooltip failed: {1}.", Err.Message)
		return false
	}
}

; Returns the exact tooltip currently owned by the native tray icon.
; @returns {String} Current tooltip text, including an empty title.
TrayMenuGetTooltip() {
	return A_IconTip
}

; Returns how many rows a native menu holds, separators included.
; AHK v2 exposes no row count, so callers that walk a rendered menu read it here.
; @param TargetMenu {Menu} A rendered AHK menu.
; @returns {Integer} The row count.
TrayMenuItemCount(TargetMenu) {
	Count := DllCall("GetMenuItemCount", "ptr", TargetMenu.Handle, "int")
	if (Count < 0) {
		throw OSError(A_LastError, -1, "GetMenuItemCount failed")
	}
	return Count
}

; Reads the exact captured native menu handle used by an owning operation.
; @param Handle {Integer} Captured HMENU, without reacquiring Menu.Handle.
; @returns {Integer} Native row count, or -1 when the handle is unavailable.
TrayMenuHandleItemCount(Handle) {
	return DllCall("GetMenuItemCount", "ptr", Handle, "int")
}

; Reads a child from the same captured native parent during owned-tree cleanup.
; @param Handle {Integer} Captured parent HMENU.
; @param Position {Integer} Zero-based row position.
; @returns {Integer} Native submenu handle, or 0 when the row has no submenu.
TrayMenuSubmenuHandle(Handle, Position) {
	return DllCall("GetSubMenu", "ptr", Handle, "int", Position, "ptr")
}

; Tells whether the row at a zero-based position of a native menu is a separator.
; @param TargetMenu {Menu} A rendered AHK menu.
; @param Position {Integer} Zero-based row position.
; @returns {Boolean} True for a separator row.
TrayMenuIsSeparatorAt(TargetMenu, Position) {
	static MF_BYPOSITION := 0x400, MF_SEPARATOR := 0x800, MF_POPUP := 0x10
	State := DllCall("GetMenuState", "ptr", TargetMenu.Handle, "uint", Position, "uint", MF_BYPOSITION, "uint")
	if (State == 0xFFFFFFFF)
		return false
	; For a row that opens a submenu, only the low byte holds flags: the high
	; byte is the submenu's row count, and 0x800 is one of its bits. A submenu
	; of 8 to 15 rows read as a separator, and the normaliser deleted it.
	if (State & MF_POPUP)
		return false
	return (State & MF_SEPARATOR) != 0
}

/** Ends native navigation before a failed or reentered popup can be painted. */
TrayMenuCancelNavigation() {
	return DllCall("EndMenu", "int") != 0
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


/**
 * Reads the exact caption at an existing native menu position.
 * @param {Menu} TargetMenu Actual native destination.
 * @param {Integer} Position Zero-based existing row position.
 * @returns {String} Native UTF-16 caption, including an empty separator label.
 */
TrayMenuItemCaption(TargetMenu, Position) {
	if !(TargetMenu is Menu) || Type(Position) != "Integer" || Position < 0
		|| Position >= TrayMenuItemCount(TargetMenu)
		throw ValueError("Native menu caption requires an existing row position")
	Handle := TargetMenu.Handle
	Length := DllCall("GetMenuStringW", "ptr", Handle, "uint", Position,
		"ptr", 0, "int", 0, "uint", 0x400, "int")
	TextBuffer := Buffer((Length + 1) * 2, 0)
	Read := DllCall("GetMenuStringW", "ptr", Handle, "uint", Position,
		"ptr", TextBuffer, "int", Length + 1, "uint", 0x400, "int")
	if Read != Length
		throw Error("Native menu caption changed while reading")
	return StrGet(TextBuffer, "UTF-16")
}

/**
 * Owns the finite native menu receipt and retirement operations.
 * The include bootstrap retains intrinsics before an external DATA provider runs.
 * Capture requires the current native class; retirement uses the already-held class.
 * @param {String} Operation One of current, capture, ids, count, or release.
 * @param {Menu|Boolean} Target Actual native menu for capture or owned retirement.
 * @param {Integer} Handle Previously captured native HMENU for retirement.
 * @returns {Boolean|Array|Integer} Native evidence or the completed operation result.
 */
TrayMenuFrameNative(Operation, Target := false, Handle := 0) {
	static NativeClass := Menu, NativeDll := DllCall
	static HandleGetter := Object.Prototype.GetOwnPropDesc.Call(Menu.Prototype, "Handle").Get
	static DeleteMethod := Object.Prototype.GetOwnPropDesc.Call(Menu.Prototype, "Delete").Call
	static NameGetter := Object.Prototype.GetOwnPropDesc.Call(Func.Prototype, "Name").Get
	static BuiltInGetter := Object.Prototype.GetOwnPropDesc.Call(Func.Prototype, "IsBuiltIn").Get
	HeldLive() {
		if NativeDll != DllCall
			return false
		for Callable in [NativeDll, HandleGetter, DeleteMethod, NameGetter, BuiltInGetter] {
			if !(Callable is Func) || ObjGetBase(Callable) != Func.Prototype
				return false
			for Name in ObjOwnProps(Callable)
				return false
		}
		for Pair in [["Name", NameGetter], ["IsBuiltIn", BuiltInGetter]] {
			Name := Pair[1], Getter := Pair[2]
			if !Object.Prototype.HasOwnProp.Call(Func.Prototype, Name)
				return false
			Descriptor := Object.Prototype.GetOwnPropDesc.Call(Func.Prototype, Name)
			if !Object.Prototype.HasOwnProp.Call(Descriptor, "Get") || Descriptor.Get != Getter
				return false
			for Field in ObjOwnProps(Descriptor)
				if Field != "Get"
					return false
		}
		return true
	}
	if !HeldLive() {
		if Operation == "current" || Operation == "capture"
			return false
		throw Error("Owned native menu operation lost its retained intrinsics")
	}
	if Operation == "current" {
		if NativeClass != Menu || !Object.Prototype.HasOwnProp.Call(NativeClass.Prototype, "Handle")
			|| !Object.Prototype.HasOwnProp.Call(NativeClass.Prototype, "Delete")
			return false
		HandleDescriptor := Object.Prototype.GetOwnPropDesc.Call(NativeClass.Prototype, "Handle")
		DeleteDescriptor := Object.Prototype.GetOwnPropDesc.Call(NativeClass.Prototype, "Delete")
		if !Object.Prototype.HasOwnProp.Call(HandleDescriptor, "Get") || HandleDescriptor.Get != HandleGetter
			|| !Object.Prototype.HasOwnProp.Call(DeleteDescriptor, "Call") || DeleteDescriptor.Call != DeleteMethod
			return false
		for Field in ObjOwnProps(HandleDescriptor)
			if Field != "Get"
				return false
		for Field in ObjOwnProps(DeleteDescriptor)
			if Field != "Call"
				return false
		BuiltIn := BuiltInGetter.Call(NativeDll)
		if !HeldLive() || !BuiltIn
			return false
		Name := NameGetter.Call(NativeDll)
		return HeldLive() && Name == "DllCall" && NativeClass == Menu
	}
	if Operation == "capture" {
		if NativeClass != Menu || !(Target is NativeClass) || ObjGetBase(Target) != NativeClass.Prototype
			|| Object.Prototype.HasOwnProp.Call(Target, "Handle")
			return false
		Handle := HandleGetter.Call(Target)
		if !HeldLive() || !NativeDll.Call("IsMenu", "ptr", Handle, "int")
			return false
		Count := NativeDll.Call("GetMenuItemCount", "ptr", Handle, "int")
		if Count < 0
			return false
		Rows := []
		loop Count {
			if !HeldLive()
				return false
			Position := A_Index - 1
			State := NativeDll.Call("GetMenuState", "ptr", Handle, "uint", Position, "uint", 0x400, "uint")
			if State == 0xFFFFFFFF
				return false
			Length := NativeDll.Call("GetMenuStringW", "ptr", Handle, "uint", Position,
				"ptr", 0, "int", 0, "uint", 0x400, "int")
			TextBuffer := Buffer((Length + 1) * 2, 0)
			Read := NativeDll.Call("GetMenuStringW", "ptr", Handle, "uint", Position,
				"ptr", TextBuffer, "int", Length + 1, "uint", 0x400, "int")
			if Read != Length
				return false
			Id := NativeDll.Call("GetMenuItemID", "ptr", Handle, "int", Position, "uint")
			Child := NativeDll.Call("GetSubMenu", "ptr", Handle, "int", Position, "ptr")
			Rows.Push([StrGet(TextBuffer, "UTF-16"), Id, State, Child])
		}
		if !HeldLive() || Object.Prototype.HasOwnProp.Call(Target, "Handle")
			|| HandleGetter.Call(Target) != Handle
			return false
		return HeldLive() && NativeDll.Call("GetMenuItemCount", "ptr", Handle, "int") == Count ? [Handle, Rows] : false
	}
	if Type(Handle) != "Integer" || Handle <= 0
		throw ValueError("Owned native menu operation requires its captured handle")
	if Operation == "count"
		return NativeDll.Call("GetMenuItemCount", "ptr", Handle, "int")
	if !(Target is NativeClass) || ObjGetBase(Target) != NativeClass.Prototype
		|| HandleGetter.Call(Target) != Handle || !HeldLive()
		throw Error("Owned native menu retirement lost its captured handle")
	if Operation == "ids" {
		Ids := [], Count := NativeDll.Call("GetMenuItemCount", "ptr", Handle, "int")
		if Count >= 0 {
			loop Count {
				if !HeldLive()
					throw Error("Owned native menu enumeration lost its retained intrinsics")
				Ids.Push(NativeDll.Call("GetMenuItemID", "ptr", Handle, "int", A_Index - 1, "uint"))
			}
		}
		if !HeldLive()
			throw Error("Owned native menu enumeration lost its retained intrinsics")
		return Ids
	}
	if Operation == "release" {
		DeleteMethod.Call(Target)
		return true
	}
	throw ValueError("Unknown owned native menu operation")
}
