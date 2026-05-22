; ui/llm_model_browser.ahk

; ==============================================================================
; MODULE: LLM Model Browser
; DESCRIPTION:
; Visual model browser with rich per-model specs (parameters, RAM footprint,
; speed, type). Replaces the "flat list of Ollama tags" picker for users who
; want to compare models side by side before picking one. Mirrors the HS
; ui/menu/menu_llm/models_manager visual catalogue so both drivers expose
; the same level of metadata at selection time.
;
; FEATURES & RATIONALE:
; 1. Catalogue-first — the list comes from the shared models.json (not from
;    ``ollama list``), so the user can survey models they have not installed
;    yet and decide based on specs. The "Status" column tells them what is
;    already on disk so they can sort installed-first.
; 2. Sortable ListView — clicking a column header sorts ascending /
;    descending, exactly like a file manager. Useful to find the smallest
;    model that still fits in RAM, or the fastest among the chat-type ones.
; 3. Double-click = select — the row's display name flows through the same
;    ``LLM_Tray_SetModel`` path as the menu picker, so the deps checker is
;    triggered when the user picks something not yet installed. No special-
;    case install flow lives in this file.
; ==============================================================================

#Requires AutoHotkey v2.0


; Module-level Gui handle so a second call brings the existing window to
; the front instead of stacking duplicates.
global _LLM_ModelBrowser_Gui := unset

; Column index of "params" in the ListView — kept as a constant so the
; sort-on-header handler can resolve it without a magic number. Indices
; match the Add() order below.
global LLM_MB_COL_NAME      := 1
global LLM_MB_COL_FAMILY    := 2
global LLM_MB_COL_PARAMS    := 3
global LLM_MB_COL_RAM       := 4
global LLM_MB_COL_SPEED     := 5
global LLM_MB_COL_TYPE      := 6
global LLM_MB_COL_STATUS    := 7





; ====================================
; ====================================
; ======= 1/ Public Entry Point ======
; ====================================
; ====================================

/**
 * Opens (or brings forward) the visual model browser. The Gui is built
 * once and reused — closing it hides it instead of destroying so the
 * next call is instantaneous. Returns the Gui handle for chained tests.
 *
 * @returns {Gui} The browser window handle.
 */
LLM_ModelBrowser_Show() {
	global _LLM_ModelBrowser_Gui, _LLM_Tray
	if IsSet(_LLM_ModelBrowser_Gui) {
		; A reused Gui that fails to refresh (e.g. models.json was edited
		; and re-parses badly) used to fall through to rebuild a SECOND
		; Gui without destroying the first — Gui handle leak. Catch the
		; failure, destroy the stale Gui, and let the rebuild path run.
		try {
			_LLM_ModelBrowser_Gui.Show()
			_LLM_ModelBrowser_RefreshRows(_LLM_ModelBrowser_Gui.ListView)
			return _LLM_ModelBrowser_Gui
		} catch {
			try _LLM_ModelBrowser_Gui.Destroy()
			_LLM_ModelBrowser_Gui := unset
		}
	}
	_LLM_ModelBrowser_Gui := _LLM_ModelBrowser_Build()
	_LLM_ModelBrowser_Gui.Show()
	return _LLM_ModelBrowser_Gui
}





; ====================================
; ====================================
; ======= 2/ Gui Construction ========
; ====================================
; ====================================

/**
 * Builds the browser Gui with a sortable ListView and a footer of action
 * buttons. The Gui itself is hidden until the caller invokes Show().
 *
 * @returns {Gui} New browser window.
 */
_LLM_ModelBrowser_Build() {
	; Variable name is ``g`` rather than ``gui`` because AHK v2 identifiers
	; are case-insensitive: a local ``gui`` shadows the built-in ``Gui``
	; class, so ``gui := Gui(...)`` resolves the right-hand side against
	; the just-declared (and still unset) local — triggering "This local
	; variable has not been assigned a value" the first time the menu
	; fires. ``g`` (matching the convention used elsewhere in the driver)
	; sidesteps the collision entirely.
	g := Gui("+Resize +MinSize720x420", t("menu.llm.browse_models_title"))
	g.OnEvent("Close", _LLM_ModelBrowser_OnClose)
	g.OnEvent("Escape", _LLM_ModelBrowser_OnClose)
	g.MarginX := 10
	g.MarginY := 10

	g.SetFont("s10")

	; Filter row — search the table by typing a substring. Live filter on
	; every keystroke so the list narrows as the user thinks, no Apply
	; button needed. The hint label is dimmed to make the intent obvious.
	g.Add("Text",, t("menu.llm.browse_models_filter"))
	filter_edit := g.Add("Edit", "w560 vFilter")
	; Debounce the refresh: ``RefreshRows`` reloads the installed-tag list
	; via ``LLM_OllamaListModels()`` and re-runs the two-key sort over the
	; full catalogue, both of which are expensive. Without debounce a
	; fast typist locks the Gui mid-search. The timer reference is stored
	; on the Gui so SetTimer can cancel-by-identity across keystrokes.
	g.FilterDebounce := () => _LLM_ModelBrowser_RefreshRows(g.ListView, filter_edit.Value)
	filter_edit.OnEvent("Change", (*) => (
		SetTimer(g.FilterDebounce, 0),
		SetTimer(g.FilterDebounce, -120)
	))

	; ListView — columns mirror the metadata extracted in
	; LLM_LoadModelsJSON. Status reads ``ollama list`` so the user can
	; tell installed vs available at a glance, but the column is filled
	; lazily on refresh to avoid blocking the Gui at construction.
	lv := g.Add("ListView",
		"r18 w780 vListView Sort -Multi",
		[ t("menu.llm.browse_col_name")
		, t("menu.llm.browse_col_family")
		, t("menu.llm.browse_col_params")
		, t("menu.llm.browse_col_ram")
		, t("menu.llm.browse_col_speed")
		, t("menu.llm.browse_col_type")
		, t("menu.llm.browse_col_status") ])
	lv.OnEvent("DoubleClick", (LV, RowNumber) => _LLM_ModelBrowser_PickRow(LV, RowNumber))
	g.ListView := lv

	; Action footer — Pick the current selection, Close. Pick mirrors a
	; double-click so users used to right-clicking lists still discover
	; the action.
	g.Add("Button", "w120 Default", t("menu.llm.browse_pick"))
		.OnEvent("Click", (*) => _LLM_ModelBrowser_PickRow(lv, lv.GetNext(0)))
	g.Add("Button", "x+10 w120", t("button.close"))
		.OnEvent("Click", _LLM_ModelBrowser_OnClose)

	_LLM_ModelBrowser_RefreshRows(lv)
	return g
}

/**
 * Refreshes the ListView rows from the current models.json index, applying
 * an optional substring filter. Highlights the row matching the currently
 * selected model so the user can see the baseline before picking another.
 *
 * @param {ListView} lv - Target list-view control.
 * @param {string}   filter - Substring filter (case-insensitive). Empty = no filter.
 */
_LLM_ModelBrowser_RefreshRows(lv, filter := "") {
	global _LLM_Tray
	lv.Delete()
	index := LLM_GetModelIndex()
	installed := Map()
	for tag in _LLM_ModelBrowser_GetInstalledTags()
		installed[StrLower(tag)] := true
	filter_lc := StrLower(filter)
	; Two-pass population so families end up grouped together — by sorting
	; on family first, the user can quickly see all Qwen / Gemma / Llama
	; variants next to each other without having to click the column.
	names := []
	for name, _ in index
		names.Push(name)
	names := _LLM_ModelBrowser_Sort(names)
	row_for_active := 0
	active := _LLM_Tray["model"]
	for name in names {
		info := index[name]
		family := _LLM_ModelBrowser_GuessFamily(name)
		; Guard every Map read with .Has() — a partial models.json entry
		; (older revisions of the file, custom user-added entries) would
		; otherwise throw UnsetItemError and kill the browser.
		params := info.Has("params_b")    ? info["params_b"]    : 0
		params_lbl := (params > 0) ? Format("{:.2f} B", params) : "—"
		if info.Has("active_b") and info["active_b"] > 0 and info["active_b"] != params
			params_lbl := params_lbl . " (" . Format("{:.2f} B", info["active_b"]) . " active)"
		ram_val   := info.Has("ram_gb")      ? info["ram_gb"]      : 0
		ram_lbl := (ram_val > 0) ? Format("{:.1f} Go", ram_val) : "—"
		speed_val := info.Has("speed_tok_s") ? info["speed_tok_s"] : 0
		speed_lbl := (speed_val > 0) ? (speed_val . " tok/s") : "—"
		type_lbl   := info.Has("type")   ? info["type"]   : "—"
		ollama_tag := info.Has("ollama") ? info["ollama"] : ""
		status_lbl := installed.Has(StrLower(ollama_tag)) ? t("menu.llm.browse_status_installed") : t("menu.llm.browse_status_available")
		row_text := name . " | " . family . " | " . params_lbl . " | " . ram_lbl . " | " . speed_lbl . " | " . type_lbl . " | " . status_lbl
		if (filter_lc != "" and !InStr(StrLower(row_text), filter_lc))
			continue
		idx := lv.Add(, name, family, params_lbl, ram_lbl, speed_lbl, type_lbl, status_lbl)
		if (name == active)
			row_for_active := idx
	}
	loop 7
		lv.ModifyCol(A_Index, "AutoHdr")
	if (row_for_active > 0) {
		lv.Modify(row_for_active, "Select Focus Vis")
	}
}

/**
 * Returns ``names`` sorted by (family asc, params asc) so families end up
 * grouped and the smallest variant of each family appears first. Pure
 * function — does not mutate the caller's array.
 */
_LLM_ModelBrowser_Sort(names) {
	out := []
	for n in names
		out.Push(n)
	; Two-key sort via stable bubble — array sizes (~100) make the cost
	; negligible and an array-of-Maps custom sort comparator in AHK v2 is
	; clunkier than this loop.
	swapped := true
	while swapped {
		swapped := false
		loop out.Length - 1 {
			i := A_Index
			a := out[i], b := out[i+1]
			af := _LLM_ModelBrowser_GuessFamily(a)
			bf := _LLM_ModelBrowser_GuessFamily(b)
			cmp := StrCompare(af, bf, false)
			if (cmp == 0) {
				; Guard the secondary sort key the same way RefreshRows
				; guards its column reads. Missing ``params_b`` should
				; not throw — it should sort as 0 (unknown size first).
				info_a := LLM_GetModelInfo(a)
				info_b := LLM_GetModelInfo(b)
				ap := (info_a is Map and info_a.Has("params_b")) ? info_a["params_b"] : 0
				bp := (info_b is Map and info_b.Has("params_b")) ? info_b["params_b"] : 0
				cmp := (ap < bp) ? -1 : (ap > bp ? 1 : 0)
			}
			if (cmp > 0) {
				out[i] := b, out[i+1] := a
				swapped := true
			}
		}
	}
	return out
}

/**
 * Heuristic family grouping by name prefix. We do not have a "family"
 * field in the AHK model index, so reuse the model's display-name prefix
 * (everything before the first digit run) as the family — produces the
 * intuitive groups: "Qwen3-Coder-30B" → "Qwen3-Coder", "Gemma-3n-E4B" →
 * "Gemma-3n", "Llama-3.2-1B" → "Llama-3.2".
 */
_LLM_ModelBrowser_GuessFamily(name) {
	if RegExMatch(name, "^(.*?)-?\d", &m) and m.Pos == 1
		return RTrim(m[1], "-")
	return name
}

/**
 * Returns the list of locally installed Ollama tags. Mirrors the helper
 * that ``LLM_Tray_BuildModelMenu`` already uses for the flat picker, but
 * tolerated to silent failure: when the daemon is not running we simply
 * mark every entry as "available" — refreshing later (or after a manual
 * install) will pick the change up.
 *
 * ``try`` MUST wrap the function call in a block-form with a ``catch``,
 * otherwise an exception inside LLM_OllamaListModels propagates up the
 * stack and tears down the Gui. The previous ``try return …`` shorthand
 * looked like it caught the error but actually didn't.
 */
_LLM_ModelBrowser_GetInstalledTags() {
	try {
		return LLM_OllamaListModels()
	} catch {
		return []
	}
}





; ====================================
; ====================================
; ======= 3/ Action Handlers =========
; ====================================
; ====================================

/**
 * Activates the highlighted model. Routes through the standard
 * LLM_Tray_SetModel path so the deps checker and engine re-init fire
 * exactly like a click in the flat menu. Closes the browser on success.
 */
_LLM_ModelBrowser_PickRow(LV, RowNumber) {
	if (!RowNumber or RowNumber < 1)
		return
	name := LV.GetText(RowNumber, 1)
	if (name == "")
		return
	LLM_Tray_SetModel(name)
	_LLM_ModelBrowser_OnClose()
}

_LLM_ModelBrowser_OnClose(*) {
	global _LLM_ModelBrowser_Gui
	if IsSet(_LLM_ModelBrowser_Gui) {
		try _LLM_ModelBrowser_Gui.Hide()
	}
}