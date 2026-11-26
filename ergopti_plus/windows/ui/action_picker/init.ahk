; ui/action_picker/init.ahk

; ==============================================================================
; MODULE: Action & Slot Pickers (GUI dialogs)
; DESCRIPTION:
; Pickers for assigning actions to keyboard shortcut slots and the config-paths
; editor entry. ShowKeyboardSlotPicker is a native ListBox, its only form.
; ShowActionPicker and FilePathsEditor open shared WebView pages only and refuse
; without WebView2: their native fallbacks were removed (maintainer decision
; 2026-11-21). Functions are hoisted so their menu call sites are unaffected.
; ==============================================================================

#Include %A_LineFile%\..\..\..\core\ui\engine\font_scale.ahk

; Each native picker is constructed anew; default Close would only hide its
; controls and their captured callbacks instead of retiring the owned window.
_ActionPickerNativeClose(Window, *) {
	Window.Destroy()
	return true
}

ShowKeyboardSlotPicker(Prefix) {
		Slots := []
		; The keys come from the input owner's published slot domain, so a slot
		; the picker creates is always one the owner binds and the loader keeps.
		for Key in KeyboardSlotDeclaration()["keys"] {
				Slots.Push(Prefix . Key)
		}
		if (Slots.Length = 0)
				return
		SlotLabels := []
		for SlotId in Slots
				SlotLabels.Push(_FormatSlotLabel(SlotId))
		; The group's modifiers by name, never its slot prefix (`primary_shift_`).
		W := Gui_Create("", t("dialog.keyboard_shortcut.title_prefix") . _KeyboardSlotFamilyLabel(Prefix) . " + …")
		W.OnEvent("Close", _ActionPickerNativeClose)
		W.OnEvent("Escape", _ActionPickerNativeClose)
		Gui_SetFont(W, "s10", "Segoe UI")
		W.MarginX := 12
		W.MarginY := 12
		W.Add("Text", "xm", t("dialog.keyboard_shortcut.prompt"))
		LB := W.Add("ListBox", "xm w320 r16", SlotLabels)
		W.Add("Button", "xm w80", t("button.ok")).OnEvent("Click", PickSlot)
		W.Add("Button", "x+6 w80", t("button.cancel")).OnEvent("Click", (*) => W.Destroy())
		W.Show()
		PickSlot(*) {
				Idx := LB.Value
				if (Idx = 0)
						return
				W.Destroy()
				ShowKeyboardShortcutPicker(Slots[Idx])
		}
}

; BindingId, when given, is the binding the choice is for: the picker opens its
; own editor on the value that binding already holds for a send_* action.
; Slot, when given, is a slot that does not take gesture actions (a hold):
; Map("items", its own picker items, "after_close", a callable taking the
; picked id). Its pick is committed while the picker is still open: OnConfirm
; returns the integer 1 to close the picker, then after_close runs (the
; reload); any other answer keeps the picker open, as on macOS and Linux.
; Without a Slot, OnConfirm also runs while the picker is open: false keeps
; it open for another pick, any other answer closes it. Items, when given,
; replaces the catalogue's picker items for a slot that takes gesture actions
; but greys or leaves out some of them (a key chord).
ShowActionPicker(Title, Current, OnConfirm, ShowNative := false, BindingId := "", Slot := 0, Items := 0) {
		AfterClose := 0
		if (Slot is Map) {
				if !(Slot.Get("items", 0) is Array) || !HasMethod(Slot.Get("after_close", 0), "Call")
						throw ValueError("A picker slot needs its items and its after_close step.", -1)
				AfterClose := Slot["after_close"]
		} else if !((Slot is Integer) && Slot == 0) {
				throw TypeError("A picker slot is a Map.", -1, Type(Slot))
		}
		if !(Items is Array) && !((Items is Integer) && Items == 0)
				throw TypeError("Picker items are an Array.", -1, Type(Items))
		if (Items is Array) && (Slot is Map)
				throw ValueError("A picker slot already brings its own items.", -1)
		; The shared WebView2 picker is the only one (identical UI to macOS and
		; Linux). It receives the ordered items of the generated catalogue,
		; headings already localized with their level; the page injects its own
		; native/none rows. Without WebView2 it refuses with the shared message.
		PickerItems := (Slot is Map) ? Slot["items"] : (Items is Array) ? Items : GestureActionPickerItems()
		return _ActPickWeb_TryOpen(Title, Current, PickerItems, OnConfirm, ShowNative, BindingId, AfterClose)
}

; Commits a slot's pick while its picker is open (ShowActionPicker's Slot).
; @param OnConfirm {Func} The slot's owner; the integer 1 means committed.
; @param PickId {String} The picked id.
; @returns {Boolean} True when the owner committed the pick.
_ActionPickerSlotCommitted(OnConfirm, PickId) {
		Committed := false
		try Committed := OnConfirm(PickId)
		catch as Err {
				try LoggerError("ActionPicker", "The pick '{1}' could not be saved: {2}. The picker stays open.",
						PickId, Err.Message)
				return false
		}
		if (Committed is Integer) && Committed == 1
				return true
		try LoggerWarn("ActionPicker", "The pick '{1}' was refused. The picker stays open.", PickId)
		return false
}

ShowKeyboardShortcutPicker(SlotId) {
		global KeyboardShortcutAssignments
		Current := KeyboardShortcutAssignments.Has(SlotId) ? KeyboardShortcutAssignments[SlotId] : "none"
		ShowActionPicker(t("dialog.keyboard_shortcut.title_prefix") . _FormatSlotLabel(SlotId), Current,
				(Id) => SetKeyboardShortcutAction(SlotId, Id), false, GestureBindingId("keyboard", SlotId))
}

FilePathsEditor(*) {
		; The shared WebView2 editor is the only one (identical UI to macOS); without
		; WebView2 it refuses with the shared message.
		return _PathsEdWeb_TryOpen()
}
