; ui/action_picker.ahk

; ==============================================================================
; MODULE: Action & Slot Pickers (GUI dialogs)
; DESCRIPTION:
; Searchable GUI pickers for assigning actions to script/keyboard shortcut slots
; (ShowKeyboardSlotPicker, ShowActionPicker, ShowKeyboardShortcutPicker) and the
; config-paths editor (FilePathsEditor). Extracted verbatim from ErgoptiPlus.ahk
; (P4 entrypoint decomposition) and #Include'd in place; functions are hoisted so
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
            local TranslatedHeader := t("sg_actions.sg_order.header." . SubStr(ActionName, 2))
            CurrentCat := SubStr(TranslatedHeader, 1, 1) = "#" ? SubStr(TranslatedHeader, 2) : TranslatedHeader
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
    ShowActionPicker(t("dialog.keyboard_shortcut.title_prefix") . _GestureActionLabel(SlotId), Current, (Id) => SetKeyboardShortcutAction(SlotId, Id))
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
        try DirCreate(SubStr(_PathsFile, 1, InStr(_PathsFile, "\", , -1) - 1))
        f := FileOpen(_PathsFile, "w", "UTF-8")
        if f {
            f.Write('# Custom paths' . "`r`n" . 'ConfigDirPath = "' . StrReplace(N, "\", "/") . '"' . "`r`n")
            f.Close()
        }
        Reload()
    }
    W.Add("Button", "x162 y+10 w100 Default", t("button.ok")).OnEvent("Click", ConfirmPath)
    W.Show("Center")
}
