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

ShowKeyboardSlotPicker(Prefix) {
		global GESTURE_ACTIONS
		Slots := []
		static _SpecialOrder := ["space", "enter", "period", "comma", "sc029"]
		Letters := "abcdefghijklmnopqrstuvwxyz"
		loop StrLen(Letters) {
				SlotId := Prefix . SubStr(Letters, A_Index, 1)
				if GESTURE_ACTIONS.Has(SlotId)
						Slots.Push(SlotId)
		}
		loop 10 {
				SlotId := Prefix . SubStr("0123456789", A_Index, 1)
				if GESTURE_ACTIONS.Has(SlotId)
						Slots.Push(SlotId)
		}
		for Sk in _SpecialOrder {
				SlotId := Prefix . Sk
				if GESTURE_ACTIONS.Has(SlotId)
						Slots.Push(SlotId)
		}
		if (Slots.Length = 0)
				return
		SlotLabels := []
		for SlotId in Slots
				SlotLabels.Push(_GestureActionLabel(SlotId))
		W := Gui_Create("+AlwaysOnTop", t("dialog.keyboard_shortcut.title_prefix") . Prefix)
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

ShowActionPicker(Title, Current, OnConfirm, ShowNative := false) {
		global GESTURE_ACTION_NAMES, GESTURE_ACTIONS
		; Prefer the shared WebView2 picker (identical UI to macOS). It receives the
		; ordered item list (headings carry their level, derived from the number of
		; leading "#" on the catalogue entry; the page injects its own native/none
		; rows). The native searchable ListBox below remains as an automatic fallback.
		_apItems := []
		for _apName in GESTURE_ACTION_NAMES {
				if (_apName == "--" or _apName == "none")
						continue
				if (SubStr(_apName, 1, 1) = "#") {
						_apLvl := 0
						while (SubStr(_apName, _apLvl + 1, 1) = "#")
								_apLvl++
						_apHeaderId := SubStr(_apName, _apLvl + 1)
						_apHdr := t("sg_actions.sg_order.header." . _apHeaderId)
						if (_apHdr = "sg_actions.sg_order.header." . _apHeaderId)
								_apHdr := _apHeaderId
						; The locale value carries a legacy "#" prefix — strip it so the level
						; comes only from the catalogue marker, not the translated text.
						while (SubStr(_apHdr, 1, 1) = "#")
								_apHdr := SubStr(_apHdr, 2)
						_apItems.Push({ Type: "heading", Level: _apLvl, Text: _apHdr })
						continue
				}
				if GESTURE_ACTIONS.Has(_apName)
						_apItems.Push({ Type: "action", Id: _apName, Label: _GestureActionLabel(_apName) })
		}
		if _ActPickWeb_TryOpen(Title, Current, _apItems, OnConfirm, ShowNative)
				return
		AllItems := []
		_PushItem(Id, Label, Cat) {
				AllItems.Push({ Id: Id, Label: Label, Cat: Cat })
		}
		if ShowNative
				_PushItem("__native__", t("tap_hold.tap.none"), "")
		_PushItem("none", t("dialog.action_picker.disabled"), "")
		CurrentCat := ""
		for ActionName in GESTURE_ACTION_NAMES {
				if (ActionName == "--" or ActionName == "none")
						continue
				if (SubStr(ActionName, 1, 1) = "#") {
						; Level-aware: strip every leading "#" (h1/h2/…) from the catalogue
						; marker to resolve the locale key, and any legacy "#" from the value.
						local _hl := 0
						while (SubStr(ActionName, _hl + 1, 1) = "#")
								_hl++
						local HeaderId := SubStr(ActionName, _hl + 1)
						local TranslatedHeader := t("sg_actions.sg_order.header." . HeaderId)
						if (TranslatedHeader = "sg_actions.sg_order.header." . HeaderId)
								TranslatedHeader := HeaderId
						while (SubStr(TranslatedHeader, 1, 1) = "#")
								TranslatedHeader := SubStr(TranslatedHeader, 2)
						CurrentCat := TranslatedHeader
						continue
				}
				if GESTURE_ACTIONS.Has(ActionName)
						_PushItem(ActionName, _GestureActionLabel(ActionName), CurrentCat)
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
		W := Gui_Create("+AlwaysOnTop", Title)
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
				W.Destroy()
				OnConfirm((ChosenId == "__native__") ? "" : ChosenId)
		}
}

ShowKeyboardShortcutPicker(SlotId) {
		global KeyboardShortcutAssignments
		Current := KeyboardShortcutAssignments.Has(SlotId) ? KeyboardShortcutAssignments[SlotId] : "none"
		ShowActionPicker(t("dialog.keyboard_shortcut.title_prefix") . _FormatSlotLabel(SlotId), Current, (Id) => SetKeyboardShortcutAction(SlotId, Id))
}

FilePathsEditor(*) {
		global _ConfigDir, _PathsFile
		; Prefer the shared WebView2 editor (identical UI to macOS); the native
		; single-field dialog below remains as an automatic fallback.
		if _PathsEdWeb_TryOpen()
				return
		W := Gui(, t("dialog.config_folder.title"))
		W.SetFont("s10", "Segoe UI")
		W.MarginX := 12
		W.MarginY := 12
		W.Add("Text", "xm w400", t("dialog.config_folder.label"))
		DirEdit := W.Add("Edit", "xm w400", StrReplace(_ConfigDir, "\", "/"))
		W.Add("Button", "xm y+6 w80", t("common.browse")).OnEvent("Click", (*) => ( (S := DirSelect("*" . StrReplace(Trim(DirEdit.Value), "/", "\"), 1, t("dialog.config_folder.select_title"))) != "" ? DirEdit.Value := StrReplace(S, "\", "/") : 0 ))
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
