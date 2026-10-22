; ui/action_picker/init.ahk

; ==============================================================================
; MODULE: Action & Slot Pickers (GUI dialogs)
; DESCRIPTION:
; Searchable GUI pickers for assigning actions to script/keyboard shortcut slots
; (ShowKeyboardSlotPicker, ShowActionPicker, ShowKeyboardShortcutPicker) and the
; config-paths editor (FilePathsEditor). Extracted verbatim from ErgoptiPlus.ahk
; (the entry-point decomposition) and #Include'd in place; functions are hoisted so
; their menu call sites are unaffected.
; ==============================================================================

; Each native picker is constructed anew; default Close would only hide its
; controls and their captured callbacks instead of retiring the owned window.
_ActionPickerNativeClose(Window, *) {
	Window.Destroy()
	return true
}

ShowKeyboardSlotPicker(Prefix) {
		global GESTURE_ACTIONS
		Slots := []
		; The keys come from the input owner's published slot domain, so a slot
		; the picker creates is always one the owner binds and the loader keeps.
		for Key in KeyboardSlotDeclaration()["keys"] {
				SlotId := Prefix . Key
				if GESTURE_ACTIONS.Has(SlotId)
						Slots.Push(SlotId)
		}
		if (Slots.Length = 0)
				return
		SlotLabels := []
		for SlotId in Slots
				SlotLabels.Push(_GestureActionLabel(SlotId))
		W := Gui_Create("", t("dialog.keyboard_shortcut.title_prefix") . Prefix)
		W.OnEvent("Close", _ActionPickerNativeClose)
		W.OnEvent("Escape", _ActionPickerNativeClose)
		W.SetFont("s10", "Segoe UI")
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
ShowActionPicker(Title, Current, OnConfirm, ShowNative := false, BindingId := "", Slot := 0) {
		AfterClose := 0
		if (Slot is Map) {
				if !(Slot.Get("items", 0) is Array) || !HasMethod(Slot.Get("after_close", 0), "Call")
						throw ValueError("A picker slot needs its items and its after_close step.", -1)
				AfterClose := Slot["after_close"]
		} else if !((Slot is Integer) && Slot == 0) {
				throw TypeError("A picker slot is a Map.", -1, Type(Slot))
		}
		; Prefer the shared WebView2 picker (identical UI to macOS and Linux). It
		; receives the ordered items of the generated catalogue, headings already
		; localized with their level; the page injects its own native/none rows.
		; The native searchable ListBox below remains as an automatic fallback.
		PickerItems := (Slot is Map) ? Slot["items"] : GestureActionPickerItems()
		if _ActPickWeb_TryOpen(Title, Current, PickerItems, OnConfirm, ShowNative, BindingId, AfterClose)
				return
		AllItems := []
		_PushItem(Id, Label, Cat) {
				AllItems.Push({ Id: Id, Label: Label, Cat: Cat })
		}
		if ShowNative
				_PushItem("__native__", t("tap_hold.tap.none"), "")
		_PushItem("none", t("dialog.action_picker.disabled"), "")
		; The ListBox has one level of grouping: every heading, whatever its
		; level, starts the category the rows below it are shown under.
		CurrentCat := ""
		for _, Item in PickerItems {
				if Item.HasOwnProp("Id") && Item.Id == "run_program"
						&& (!IsSet(ProgramActions_Available) || !IsSet(ProgramActions_BindingSupported)
				|| !ProgramActions_Available() || !ProgramActions_BindingSupported(BindingId))
						continue
				if (Item.Type = "heading")
						CurrentCat := Item.Text
				else
						_PushItem(Item.Id, Item.Label, CurrentCat)
		}
		BuildListRows(Items) {
				Ids := []
				Labels := []
				LastCat := Chr(0)
				for Item in Items {
						if (Item.Cat != "" and Item.Cat != LastCat) {
								Ids.Push("")
								Labels.Push("▸ " . Item.Cat)
								LastCat := Item.Cat
						}
						Ids.Push(Item.Id)
						Labels.Push("    " . Item.Label)
				}
				return { Ids: Ids, Labels: Labels }
		}
		Rows := BuildListRows(AllItems)
		FilteredIds := Rows.Ids
		SelectedIdx := 0
		LookupId := (Current == "") ? "__native__" : Current
		for i, Id in FilteredIds {
				if (Id == LookupId) {
						SelectedIdx := i
						break
				}
		}
		W := Gui_Create("", Title)
		W.OnEvent("Close", _ActionPickerNativeClose)
		W.OnEvent("Escape", _ActionPickerNativeClose)
		W.SetFont("s10", "Segoe UI")
		W.MarginX := 12
		W.MarginY := 12
		W.Add("Text", "xm", t("dialog.action_picker.label"))
		SearchEdit := W.Add("Edit", "xm w340")
		LB := W.Add("ListBox", "xm w340 r20", Rows.Labels)
		if (SelectedIdx > 0)
				LB.Choose(SelectedIdx)
		W.Add("Button", "xm w80", t("button.ok")).OnEvent("Click", ConfirmPick)
		W.Add("Button", "x+6 w80", t("button.cancel")).OnEvent("Click", (*) => W.Destroy())
		W.Show()
		SearchEdit.OnEvent("Change", FilterList)
		FilterList(*) {
				Query := StrLower(SearchEdit.Value)
				Matched := []
				if (Query == "") {
						Matched := AllItems
				} else {
						for Item in AllItems {
								if InStr(StrLower(Item.Label), Query)
										Matched.Push(Item)
						}
				}
				NewRows := BuildListRows(Matched)
				FilteredIds := NewRows.Ids
				LB.Delete()
				LB.Add(NewRows.Labels)
				for i, Id in FilteredIds {
						if (Id != "") {
								LB.Choose(i)
								break
						}
				}
		}
		ConfirmPick(*) {
				Idx := LB.Value
				if (Idx = 0)
						return
				ChosenId := FilteredIds[Idx]
				if (ChosenId == "")
						return
				Mapped := (ChosenId == "__native__") ? "" : ChosenId
				if HasMethod(AfterClose, "Call") {
						; A refused pick keeps this dialog open for another pick.
						if !_ActionPickerSlotCommitted(OnConfirm, Mapped)
								return
						W.Destroy()
						AfterClose.Call(Mapped)
						return
				}
				W.Destroy()
				OnConfirm(Mapped)
		}
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
		global _ConfigDir, _PathsFile
		; Prefer the shared WebView2 editor (identical UI to macOS); the native
		; single-field dialog below remains as an automatic fallback.
		if _PathsEdWeb_TryOpen()
				return
		W := Gui_Create(, t("dialog.config_folder.window_title"))
		_PathsEdNative_BindCancellation(W)
		W.SetFont("s10", "Segoe UI")
		W.MarginX := 12
		W.MarginY := 12
		W.Add("Text", "xm w400", t("dialog.config_folder.label"))
		DirEdit := W.Add("Edit", "xm w400", StrReplace(_ConfigDir, "\", "/"))
		W.Add("Button", "xm y+6 w80", t("common.browse")).OnEvent("Click", (*) => _PathsEdNative_Browse(W, DirEdit))
		ConfirmPath(*) {
				N := StrReplace(Trim(DirEdit.Value), "/", "\")
				if (N == "")
						N := _DefaultConfigDir
				if !RegExMatch(N, "\\$")
						N .= "\"
				if (N == _ConfigDir) {
						W.Destroy()
						return
				}
				; Shares the single hardened writer with the WebView2 editor. This used
				; to be a verbatim copy of that block from before it was hardened: an
				; unprotected FileOpen and an `if f` with no else, so a read-only or
				; locked target discarded the user's chosen directory in silence and the
				; the writer's owned Reload dropped them back into the OLD one with no
				; error shown.
				if !_PathsFile_Write(N)
						return
		}
		W.Add("Button", "x162 y+10 w100 Default", t("button.ok")).OnEvent("Click", ConfirmPath)
		W.Show("Center")
}
