; lib/app_picker.ahk

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
;     title    : window title (required)
;     prompt   : header label above the list (required)
;     initial  : Array of lowercase process names already selected (optional)
;     on_save  : Func(selected_array) — called when user clicks OK.
;                ``selected_array`` is an Array of lowercase process names.
;     ok_label : optional override for the OK button caption
;
; The Gui is modal-by-default (OwnDialogs) so it stays on top of the
; submenu that triggered it.
; ==============================================================================

#Requires Autohotkey v2.0+





; ===============================
; ===============================
; ======= 1/ Public entry =======
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

    btn_ok.OnEvent("Click", (*) => AppPicker_OnOK(g, lv, on_save))
    btn_cancel.OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Close", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())

    g.Show()
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
AppPicker_OnOK(g, lv, on_save) {
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
    if (on_save != "" && on_save is Func)
        on_save(selected)
}





; ========================================
; ========================================
; ======= 2/ Running-app discovery =======
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
