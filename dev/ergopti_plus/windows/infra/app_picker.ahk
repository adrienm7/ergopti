; infra/app_picker.ahk

; ==============================================================================
; MODULE: App Picker (reusable Gui)
; DESCRIPTION:
; Generic « pick one or more running applications » dialog. Used by the
; metrics privacy filter to build the per-app exclusion list, and meant
; to be reused as-is by future features (e.g. excluding apps from AI
; predictions). The Gui is stateless across calls — every show creates
; a fresh window and resolves through a callback or return value.
;
; FEATURES & RATIONALE:
; 1. Reusable contract: AppPicker_Show(opts) takes a config object and
;    invokes opts.on_save with the array of selected process names.
;    No globals, no internal coupling to any specific feature.
; 2. Currently-focused app pinned at the top: the user's intent is most
;    often to exclude / pick the app they were just looking at, so the
;    UI surfaces it first. The same row also displays « (en cours) ».
; 3. Lists every app that owns at least one visible top-level window
;    (using WinGetList with no filter and walking up to the root). De-
;    duplicated on process name. Sorted alphabetically except the
;    focused app stays anchored on top.
; 4. Pre-checked initial state: opts.initial reflects what the caller
;    already considers selected; this lets the dialog double as an
;    edit-existing-list view.
;
; CONTRACT:
;   AppPicker_Show(opts) where opts is a Map with keys:
;     owner    : stable logical setting name (required)
;     title    : window title (required)
;     prompt   : header label above the list (required)
;     initial  : Array of lowercase process names already selected (optional)
;     on_save  : callable(selected_array, receipt) — called when user clicks OK.
;                ``selected_array`` is an Array of lowercase process names.
;                ``receipt`` must be claimed inside the durable candidate build.
;     ok_label : optional override for the OK button caption
;
; The Gui is deliberately nonmodal: more than one window can exist, so every
; callback is fenced by the logical-owner receipt described below.
; ==============================================================================

#Requires Autohotkey v2.0+

global _AppPickerOwnerEpochs := Map()
global _AppPickerActiveReceipts := Map()





; =====================================
; =====================================
; ======= 1/ Ownership receipts =======
; =====================================
; =====================================

; Normalizes either an Array selection or the Metrics Map representation into
; one detached set. The picker compares sets, not display order.
AppPicker_NormalizeSelection(Value) {
	Normalized := Map()
	try {
		if Value is Array {
			for Item in Value {
				Key := StrLower(Trim(String(Item)))
				if (Key != "")
					Normalized[Key] := true
			}
			return Normalized
		}
		if Value is Map {
			for Item, Enabled in Value {
				if !Enabled
					continue
				Key := StrLower(Trim(String(Item)))
				if (Key != "")
					Normalized[Key] := true
			}
			return Normalized
		}
	}
	return false
}

AppPicker_SelectionsEqual(Left, Right) {
	LeftSet := AppPicker_NormalizeSelection(Left)
	RightSet := AppPicker_NormalizeSelection(Right)
	if !(LeftSet is Map) || !(RightSet is Map)
		return false
	if (LeftSet.Count != RightSet.Count)
		return false
	for Key, _ in LeftSet {
		if !RightSet.Has(Key)
			return false
	}
	return true
}

; Opening a picker supersedes every older window for the same logical setting.
; Different features use different owner names and remain independent.
AppPicker_IssueReceipt(Owner, BaseSelection) {
	global _AppPickerOwnerEpochs, _AppPickerActiveReceipts
	if !(Owner is String) || (Owner == "")
		return false
	Base := AppPicker_NormalizeSelection(BaseSelection)
	if !(Base is Map)
		return false
	PreviousCritical := Critical("On")
	try {
		Epoch := _AppPickerOwnerEpochs.Get(Owner, 0) + 1
		_AppPickerOwnerEpochs[Owner] := Epoch
		Receipt := Map("owner", Owner, "epoch", Epoch, "base", Base,
			"state", "open")
		_AppPickerActiveReceipts[Owner] := Receipt
		return Receipt
	} finally Critical(PreviousCritical)
}

; Any non-picker producer of the same setting advances the owner too. This is
; the version half of the receipt contract: a value that changes A->B->A while
; a window is open must not make that old window current again.
AppPicker_AdvanceOwner(Owner) {
	global _AppPickerOwnerEpochs, _AppPickerActiveReceipts
	if !(Owner is String) || Owner == ""
		return false
	PreviousCritical := Critical("On")
	try {
		_AppPickerOwnerEpochs[Owner] := _AppPickerOwnerEpochs.Get(Owner, 0) + 1
		if _AppPickerActiveReceipts.Has(Owner) {
			Receipt := _AppPickerActiveReceipts[Owner]
			if (Receipt is Map) && Receipt.Get("state", "") == "open"
				Receipt["state"] := "retired"
			_AppPickerActiveReceipts.Delete(Owner)
		}
		return true
	} finally Critical(PreviousCritical)
}

; Claims exactly one still-current receipt while the caller owns its durable
; configuration transaction. Both identity and detached base are checked: an
; older GUI cannot overwrite a newer picker or a setting changed elsewhere.
AppPicker_ClaimReceipt(Receipt, LiveSelection) {
	global _AppPickerOwnerEpochs, _AppPickerActiveReceipts
	PreviousCritical := Critical("On")
	try {
		if !(Receipt is Map) || !Receipt.Has("owner")
				|| !Receipt.Has("epoch") || !Receipt.Has("base")
				|| Receipt.Get("state", "") != "open"
			return false
		Owner := Receipt["owner"]
		if !(Owner is String) || !_AppPickerActiveReceipts.Has(Owner)
			return false
		if (_AppPickerActiveReceipts[Owner] != Receipt)
			return false
		if (_AppPickerOwnerEpochs.Get(Owner, 0) != Receipt["epoch"])
			return false
		if !AppPicker_SelectionsEqual(Receipt["base"], LiveSelection)
			return false
		Receipt["state"] := "claimed"
		_AppPickerActiveReceipts.Delete(Owner)
		return true
	} finally Critical(PreviousCritical)
}

AppPicker_RetireReceipt(Receipt) {
	global _AppPickerActiveReceipts
	if !(Receipt is Map) || !Receipt.Has("owner")
		return false
	PreviousCritical := Critical("On")
	try {
		Owner := Receipt["owner"]
		if _AppPickerActiveReceipts.Has(Owner)
				&& _AppPickerActiveReceipts[Owner] == Receipt
			_AppPickerActiveReceipts.Delete(Owner)
		if (Receipt.Get("state", "") == "open")
			Receipt["state"] := "retired"
		return true
	} finally Critical(PreviousCritical)
}

AppPicker_InvokeSave(OnSave, Selected, Receipt) {
	if !HasMethod(OnSave, "Call") {
		AppPicker_RetireReceipt(Receipt)
		return false
	}
	try return OnSave.Call(Selected, Receipt)
	finally AppPicker_RetireReceipt(Receipt)
}





; ===============================
; ===============================
; ======= 2/ Public entry =======
; ===============================
; ===============================

AppPicker_Show(opts) {
		if !(opts is Map) {
				; Defensive — mis-call must not crash the caller.
				return
		}
		title := opts.Has("title") ? opts["title"] : t("dialog.app_picker.title")
		prompt := opts.Has("prompt") ? opts["prompt"] : t("dialog.app_picker.prompt")
		ok_label := opts.Has("ok_label") ? opts["ok_label"] : t("common.ok")
		on_save := opts.Has("on_save") ? opts["on_save"] : ""
		owner := opts.Has("owner") ? opts["owner"] : ""
		if !HasMethod(on_save, "Call") || !(owner is String) || owner == ""
				return false

		initial := Map()
		if opts.Has("initial") && opts["initial"] is Array {
				for n in opts["initial"]
						initial[StrLower(n)] := true
		}

		rows := AppPicker_BuildRows(initial)

		g := Gui_Create("+Resize +MinSize400x500", title)
		g.SetFont("s10")
		g.MarginX := 14
		g.MarginY := 14
		g.AddText("w400", prompt)

		; ListView with checkboxes. ProcessName column is the canonical key;
		; DisplayName is friendlier for the user (window title fallback).
		lv := g.AddListView("Checked w480 r18 Grid -Multi", ["Application", "Processus"])
		lv.ModifyCol(1, 320)
		lv.ModifyCol(2, 160)
		for row in rows {
				idx := lv.Add(row.checked ? "Check" : "", row.display, row.process)
		}

		; Footer: count + buttons.
		g.AddText("xs y+10 w300 vAppPickerStatus",
				StrReplace(t("dialog.app_picker.running_count"), "{n}", rows.Length))
		; Auto-sized OK / Cancel pair — harmonised so both buttons share the
		; widest natural width (prevents clipping of long localised labels like
		; German "Abbrechen" or Portuguese "Cancelar" inside a fixed w100).
		btn_ok     := g.AddButton("x+10 yp-4 Default", ok_label)
		btn_cancel := g.AddButton("x+5 yp",            t("common.cancel"))
		Gui_HarmoniseButtonWidths([btn_ok, btn_cancel])

		; The owner is published only after construction succeeds and immediately
		; before the window becomes actionable. A failed GUI build leaves no stale
		; receipt, and the last window made usable is the newest logical owner.
		receipt := AppPicker_IssueReceipt(owner, initial)
		if !(receipt is Map) {
				g.Destroy()
				return false
		}
		try {
				btn_ok.OnEvent("Click", (*) => AppPicker_OnOK(g, lv, on_save, receipt))
				btn_cancel.OnEvent("Click", (*) => AppPicker_OnCancel(g, receipt))
				g.OnEvent("Close", (*) => AppPicker_OnCancel(g, receipt))
				g.OnEvent("Escape", (*) => AppPicker_OnCancel(g, receipt))
				g.Show()
				return receipt
		} catch {
				AppPicker_RetireReceipt(receipt)
				try g.Destroy()
				throw
		}
}

; Collect the ticked rows and hand them to the caller's on_save callback.
;
; The process name is read back OUT of the control (column 2), never out of the
; construction-time ``rows`` array: an AHK v2 ListView created without the
; ``NoSort`` option reorders its items in place as soon as the user clicks a
; column header, and the checkbox state travels with the item while ``rows``
; stays in its original order. Indexing the model with a DISPLAY row number
; therefore returned a different application than the one that was ticked —
; silently, because the index always stayed in range (app-picker-listview-sort-
; index). The control is the only object the sort touches, so it is the only
; object allowed to answer "which app is on row N".
AppPicker_OnOK(g, lv, on_save, receipt) {
		selected := []
		row_idx := 0
		loop {
				row_idx := lv.GetNext(row_idx, "Checked")
				if !row_idx
						break
				proc := StrLower(Trim(lv.GetText(row_idx, 2)))
				if (proc == "")
						continue
				selected.Push(proc)
		}
		g.Destroy()
		return AppPicker_InvokeSave(on_save, selected, receipt)
}

AppPicker_OnCancel(g, receipt) {
		AppPicker_RetireReceipt(receipt)
		g.Destroy()
}





; ========================================
; ========================================
; ======= 3/ Running-app discovery =======
; ========================================
; ========================================

; Build the row list that feeds the ListView. Each row is a Map with
; { process, display, checked }. The currently focused app is pinned
; on top with " (en cours)" appended; everything else sorted alpha.
AppPicker_BuildRows(initial) {
		rows := []
		seen := Map()
		focused_proc := ""
		focused_disp := ""
		try {
				focused_hwnd := WinGetID("A")
				if focused_hwnd {
						focused_proc := StrLower(WinGetProcessName("ahk_id " . focused_hwnd))
						focused_disp := AppPicker_FriendlyName(focused_hwnd)
				}
		}

		; Pin the focused app on top, even if it has no other top-level window
		; (e.g. menus opened over it).
		if (focused_proc != "") {
				rows.Push({
						process: focused_proc,
						display: focused_disp . t("dialog.app_picker.active_suffix"),
						checked: initial.Has(focused_proc)
				})
				seen[focused_proc] := true
		}

		others := []
		win_list := []
		try win_list := WinGetList()
		for hwnd in win_list {
				try {
						; Skip invisible / titleless windows (system trays, hidden
						; helpers) — they would clutter the list with names like
						; "Default IME" that the user has no business unchecking.
						if !DllCall("IsWindowVisible", "Ptr", hwnd)
								continue
						winTitle := WinGetTitle("ahk_id " . hwnd)
						if (winTitle = "")
								continue
						proc := StrLower(WinGetProcessName("ahk_id " . hwnd))
						if (proc = "" || seen.Has(proc))
								continue
						seen[proc] := true
						others.Push({
								process: proc,
								display: AppPicker_FriendlyName(hwnd),
								checked: initial.Has(proc)
						})
				}
		}

		; Sort the non-focused list alphabetically by display name. AHK has
		; no Array.Sort built-in for objects, so we delegate to a small
		; insertion-sort that's plenty fast for the dozen-ish entries we
		; typically deal with.
		; AHK v2: `<` on strings tries a numeric coerce and throws when the
		; operands are non-numeric. Use StrCompare() instead.
		loop others.Length {
				i := A_Index
				j := i
				while (j > 1 && StrCompare(others[j].display, others[j - 1].display, false) < 0) {
						tmp := others[j]
						others[j] := others[j - 1]
						others[j - 1] := tmp
						j -= 1
				}
		}

		for o in others
				rows.Push(o)

		; Append every "initially selected" entry that is NOT currently
		; running, so the user can still see + uncheck excluded apps that
		; happen to be closed at picker time. Greyed-display is rendered
		; via an "(arrêté)" suffix.
		for proc, _ in initial {
				if seen.Has(proc)
						continue
				rows.Push({
						process: proc,
						display: proc . t("dialog.app_picker.stopped_suffix"),
						checked: true
				})
				seen[proc] := true
		}

		return rows
}

; Return a friendly display name for a top-level window. Falls back to
; the bare executable name when no descriptive title is available.
AppPicker_FriendlyName(hwnd) {
		proc := ""
		try proc := WinGetProcessName("ahk_id " . hwnd)
		title := ""
		try title := WinGetTitle("ahk_id " . hwnd)

		; Strip the « ProcessName » suffix some apps tack on; we want the
		; human-meaningful part. Heuristic: prefer the longest segment
		; separated by " - ".
		best := ""
		if (title != "") {
				for seg in StrSplit(title, " - ") {
						seg := Trim(seg)
						if (seg != "" && StrLen(seg) > StrLen(best))
								best := seg
				}
		}
		if (best != "")
				return best
		return proc
}
