; ui/menu/menu_hotstrings.ahk

; ==============================================================================
; MODULE: Tray Menu / Hotstrings Submenu
; DESCRIPTION:
; Builds the Hotstrings category: grand-total counting, magic-key / repeat-key config, per-category delays, word expanders, delimiter editor, standard / dynamic / Ergopti / personal / extension sub-trees and their caches.
;
; Split out of ui/tray_menu.ahk (the module split). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================




global _HS_GrandTotalCache := -1

; Compute the grand total count used in the tray menu title label.
; Sums enabled standard, ergopti, dynamic, personal and extension entries.
_HS_ComputeGrandTotal() {
global Features, HotstringCategoriesStd, HotstringCategoriesErgopti
global ScriptInformation, _ExtTotalPersonalCounterGlobal, _HS_GrandTotalCache
if (_HS_GrandTotalCache != -1)
	return _HS_GrandTotalCache

; Count only ACTIVE hotstrings: sum each category's enabled-section count,
; then zero the whole total when the Hotstrings master gate is off — a
; disabled menu shows 0, never the full "what would reactivate" count.
Total := 0
for _, Cat in HotstringCategoriesStd
	Total += _CountEnabledForCategory(Cat)
for _, Cat in HotstringCategoriesErgopti
	Total += _CountEnabledForCategory(Cat)
if Features.Has("hotstrings") and Features["hotstrings"].Has("dynamic") {
	for DKey, DCfg in Features["hotstrings"]["dynamic"] {
		if (IsObject(DCfg) and DCfg.Has("enabled") and DCfg["enabled"])
			Total += CountDynamicSection(DKey)
	}
}
; ── Personal hotstrings (standard file + extensions)
PersonalActiveCount := 0
PersonalTomlPath := IsSet(ScriptInformation) ? ScriptInformation.Get("PersonalTomlPath", "") : ""
if (PersonalTomlPath != "" and FileExist(PersonalTomlPath)) {
	PersonalTomlData := ReadPersonalToml()
	for _, SecName2 in PersonalTomlData["sections_order"] {
		if (SecName2 == "-" or !PersonalTomlData["sections"].Has(SecName2))
			continue
		PV2Id    := StrLower(SecName2)
		PEnabled := Features["hotstrings"].Has("personal")
			and Features["hotstrings"]["personal"].Has(PV2Id)
			and (Features["hotstrings"]["personal"][PV2Id] is Map) and Features["hotstrings"]["personal"][PV2Id].Has("enabled") and Features["hotstrings"]["personal"][PV2Id]["enabled"]
		if PEnabled
			PersonalActiveCount += PersonalTomlData["sections"][SecName2]["entries"].Length
	}
}
Total += PersonalActiveCount
Total += IsObject(_ExtTotalPersonalCounterGlobal) ? _ExtTotalPersonalCounterGlobal.value : 0
GrandTotal := _HS_GatedCount(IsCategoryGated("Hotstrings"), Total)
_HS_GrandTotalCache := GrandTotal
return GrandTotal
}

; Invalidates hotstring-related caches.
_HS_InvalidateCaches() {
	global _HS_GrandTotalCache, _TomlCountCache
	_HS_GrandTotalCache := -1
	_TomlCountCache := Map()
}

; Dynamic handler: magic key config entry (prefix + current char + editor).
_HS_MagicKeyConfig(M, _Cat) {
	RegisterMenuItem(M, t("menu.hotstrings.magic_key_prefix") . ScriptInformation["MagicKey"], MagicKeyEditor)
}

; Dynamic handler: whole-tree bulk actions (force every hotstring section on/off).
; Rendered inside the "⚙️ Paramètres hotstrings" group, just after its separator.

; Dynamic handler: repeat-key toggle (★ as repeat key).
_HS_RepeatKey(M, _Cat) {
	global HSE_RepeatEnabled
	Label := t("menu.hotstrings.repeat_key_toggle")
	RegisterMenuItem(M, Label, ToggleRepeatKeyEnabled)
	if HSE_RepeatEnabled {
		M.Check(Label)
	}
}

; Dynamic handler: delays & colours sub-menu. Mirrors the Hammerspoon "delays"
; submenu — the per-category config window, then quick-access per-delay items
; grouped by a separator, exactly like the HS make_delay_item rows: the base
; default expansion delay, then the ★ magic-key and autocorrection per-category
; delays (settable straight from the menu, not only buried in the config window).
_HS_DelaysColors(M, _Cat) {
	global UI_LLM_TIMEOUT_SEC, DYN_HOTSTRINGS_DEFAULT_DELAY
	Sub := Menu()
	RegisterMenuItem(Sub, t("menu.hotstrings.config_item"), (*) => OpenHotstringsConfigWindow())
	Sub.Add()
	RegisterMenuItem(Sub, _HS_DefaultDelayLabel(), (*) => _HS_PromptDefaultDelay())
	RegisterMenuItem(Sub, _HS_CategoryDelayLabel("magickey", "menu.hotstrings.delay_magic_key"), (*) => _HS_PromptCategoryDelay("magickey", "menu.hotstrings.delay_magic_key"))
	RegisterMenuItem(Sub, _HS_CategoryDelayLabel("autocorrection", "menu.hotstrings.delay_autocorrection"), (*) => _HS_PromptCategoryDelay("autocorrection", "menu.hotstrings.delay_autocorrection"))
	; AI prediction tooltip auto-dismiss timeout — mirrors the HS "Délai
	; d'acceptation IA" item. No TOML [_meta] delay backs the "llm_prediction"
	; key, so its no-override default is the UI constant (20 s); the live tooltip
	; timer reads the same override (infra/tooltip.ahk).
	Sub.Add()
	RegisterMenuItem(Sub, _HS_CategoryDelayLabel("llm_prediction", "menu.hotstrings.tooltip_ai_acceptance", UI_LLM_TIMEOUT_SEC), (*) => _HS_PromptCategoryDelay("llm_prediction", "menu.hotstrings.tooltip_ai_acceptance", UI_LLM_TIMEOUT_SEC))
	; Dynamic hotstrings (dates, phone/SSN/IBAN prefixes) activation delay —
	; mirrors the HS "Délai autocomplétion" item. Backed by the "dynamichotstrings"
	; override; the no-override default is DYN_HOTSTRINGS_DEFAULT_DELAY (2 s).
	RegisterMenuItem(Sub, _HS_CategoryDelayLabel("dynamichotstrings", "menu.hotstrings.tooltip_autocompletion", DYN_HOTSTRINGS_DEFAULT_DELAY), (*) => _HS_PromptCategoryDelay("dynamichotstrings", "menu.hotstrings.tooltip_autocompletion", DYN_HOTSTRINGS_DEFAULT_DELAY))
	M.Add(t("menu.hotstrings.delays_colors"), Sub)
}

; Label for the "default expansion delay" item: "Default : <ms>[ (default)]". The
; "(default)" marker shows when no global override is set — the effective value
; is then the built-in GLOBAL_DEFAULT_DELAY fallback.
_HS_DefaultDelayLabel() {
	global _HotstringsOverrides, GLOBAL_DEFAULT_DELAY
	HasGlobal := _HotstringsOverrides.Has("_global") and _HotstringsOverrides["_global"].Delay != ""
	Seconds   := HasGlobal ? _HotstringsOverrides["_global"].Delay : GLOBAL_DEFAULT_DELAY
	Ms        := Round(Seconds * 1000)
	Display   := (Ms == 0) ? t("menu.hotstrings.infinite") : (Ms . " ms")
	; menu.settings.default_indicator already carries a leading space.
	return t("menu.hotstrings.tooltip_default") . " : " . Display . (HasGlobal ? "" : t("menu.settings.default_indicator"))
}

; Prompt for and persist the global default expansion delay (entered in ms),
; mirroring the Hammerspoon make_delay_item prompt. Reuses HotstringsSetOverride
; with the reserved "_global" key, which HotstringsResolve consults as the
; lowest-priority user value, just above the hardcoded GLOBAL_DEFAULT_DELAY.
_HS_PromptDefaultDelay() {
	global _HotstringsOverrides, GLOBAL_DEFAULT_DELAY
	HasGlobal := _HotstringsOverrides.Has("_global") and _HotstringsOverrides["_global"].Delay != ""
	CurMs     := Round((HasGlobal ? _HotstringsOverrides["_global"].Delay : GLOBAL_DEFAULT_DELAY) * 1000)
	IB := InputBox(t("menu.hotstrings.delay_prompt"), t("menu.hotstrings.tooltip_default"), "w340 h140", CurMs)
	if (IB.Result != "OK") {
		return
	}
	Val := Trim(IB.Value, " `t")
	if !RegExMatch(Val, "^\d+$") {
		MsgBox(t("menu.hotstrings.delay_invalid_body"), t("menu.hotstrings.delay_invalid_title"))
		return
	}
	HotstringsSetOverride("_global", "", "delay", (Val + 0) / 1000)
	; Persisting the override only bumps the resolve generation; delays are baked into
	; each spec at REGISTRATION time (LoadHotstringsSection folds them into the spec
	; meta), so re-register live — the same path a section toggle uses — or the new
	; delay is silently ignored until the next Reload.
	RebuildHotstringsLive()
}

; Label for a per-category default-delay item ("<name> : <ms>[ (default)]").
; Reads the EFFECTIVE delay via HotstringsResolve so it reflects the category's
; TOML [_meta] delay and any user override — the same value the config window
; shows — and marks "(default)" when the user has set no override of their own.
_HS_CategoryDelayLabel(Cat, I18nKey, DefaultSec := "") {
	R       := HotstringsResolve(Cat, "")
	; Categories with no TOML [_meta] delay (llm_prediction, dynamichotstrings)
	; pass an explicit DefaultSec; the TOML-backed ones (magickey, autocorrection)
	; leave it blank and use the resolved category default directly.
	Sec     := R.HasOverride ? R.Delay : ((DefaultSec != "") ? DefaultSec : R.Delay)
	Ms      := Round(Sec * 1000)
	Display := (Ms == 0) ? t("menu.hotstrings.infinite") : (Ms . " ms")
	; menu.settings.default_indicator already carries a leading space.
	return t(I18nKey) . " : " . Display . (R.HasOverride ? "" : t("menu.settings.default_indicator"))
}

; Prompt for and persist a per-category default expansion delay (entered in ms),
; reusing HotstringsSetOverride so the value lands in the same user-override store
; the config window writes to — both UIs therefore stay in sync.
_HS_PromptCategoryDelay(Cat, I18nKey, DefaultSec := "") {
	R     := HotstringsResolve(Cat, "")
	Sec   := R.HasOverride ? R.Delay : ((DefaultSec != "") ? DefaultSec : R.Delay)
	CurMs := Round(Sec * 1000)
	IB := InputBox(t("menu.hotstrings.delay_prompt"), t(I18nKey), "w340 h140", CurMs)
	if (IB.Result != "OK") {
		return
	}
	Val := Trim(IB.Value, " `t")
	if !RegExMatch(Val, "^\d+$") {
		MsgBox(t("menu.hotstrings.delay_invalid_body"), t("menu.hotstrings.delay_invalid_title"))
		return
	}
	HotstringsSetOverride(Cat, "", "delay", (Val + 0) / 1000)
	; Re-register live (see _HS_PromptDefaultDelay) so the new per-category delay takes
	; effect immediately instead of only after a Reload or an unrelated section toggle.
	RebuildHotstringsLive()
}

; List provider: the word-expanders sub-menu, as ROWS.
;
; Returns data rather than a Menu so the shared renderer materialises every row.
; The three drivers each rebuilt this submenu with the same logic and their own
; row API; the manifest declares it `type = "list"` now and each one answers with
; the same {label, action, checked, items} shape.
_HS_WordExpanderRows() {
	global HSE_Terminators
	Current      := HotstringsGetWordDelimiters()
	Consumed     := HotstringsGetConsumedDelimiters()
	Defs         := HSE_Terminators.all()
	BuiltinChars := HSE_TerminatorBuiltinChars()

	Rows := []

	; ── Bulk actions ─────────────────────────────────────────────────────────
	; A user turning delimiters off does it wholesale — the point of the feature
	; is "expand only on the key I chose" — and the reset is the way back, since
	; most of the catalogue ships disabled and "check all" is not that route.
	Rows.Push(Map("label", t("menu.hotstrings.check_all"),   "action", (*) => _HS_DelimSetAll(true)))
	Rows.Push(Map("label", t("menu.hotstrings.uncheck_all"), "action", (*) => _HS_DelimSetAll(false)))
	Rows.Push(Map("label", t("menu.global.reset_defaults"),  "action", (*) => _HS_DelimReset()))
	Rows.Push(Map("separator", true))

	; ── Built-in catalogue entries, in catalogue order ───────────────────────
	for _, D in Defs {
		if (D.Has("type") and D["type"] == "separator") {
			Rows.Push(Map("separator", true))
			continue
		}
		Chars := D["chars"]
		Lbl   := D["label"]
		; A consumed delimiter is swallowed by the expansion, an unconsumed one is
		; typed after it. The difference shows only in the output, so the row has
		; to say which it is. On Windows consumption is opt-in via
		; consumed_delimiters rather than the catalogue flag.
		if HSE_TerminatorAnyCharIn(Chars, Consumed)
			Lbl .= " " . t("menu.hotstrings.consumed_suffix")
		Rows.Push(Map(
			"label",   Lbl,
			"action",  ((CharsArr) => (*) => _HS_DelimToggleEntry(CharsArr))(Chars),
			"checked", HSE_TerminatorEntryEnabled(Chars, Current) ? true : false))
	}
	Rows.Push(Map("separator", true))

	; ── Custom delimiters: chars in the active string that no catalogue entry
	;    owns. Structural CR/LF belong to the "enter" entry. ──
	Loop Parse, Current {
		Ch := A_LoopField
		if (Ch == "`r" or Ch == "`n" or InStr(BuiltinChars, Ch))
			continue
		ConsumedSfx := (InStr(Consumed, Ch) > 0) ? (" " . t("menu.hotstrings.consumed_suffix")) : ""
		Rows.Push(Map(
			"label", Ch . " : " . t("menu.hotstrings.custom_label") . ConsumedSfx,
			; Always ticked: a custom delimiter exists only while it is in the
			; active string, so its presence IS its enabled state.
			"checked", true,
			"items", [Map(
				"label",  t("menu.hotstrings.delete_delimiter"),
				"action", ((C) => (*) => _HS_DelimRemoveCustom(C))(Ch))]))
	}

	Rows.Push(Map("label", t("menu.hotstrings.add_delimiter"), "action", (*) => _HS_DelimAddCustom()))

	return [Map("label", t("menu.hotstrings.word_expanders"), "items", Rows)]
}

; Toggle a whole catalogue entry (all of its chars) on/off and persist. The
; toggle logic lives in HSE_TerminatorToggleString (infra/hotstrings_config.ahk)
; so it is shared with the config window and unit-tested.
_HS_DelimToggleEntry(CharsArr) {
	HotstringsSetWordDelimiters(HSE_TerminatorToggleString(HotstringsGetWordDelimiters(), CharsArr))
	TrayTip(t("hs_config.notify_delimiters_saved"), "", "Iconi Mute")
}

; Set every built-in catalogue entry on (true) or off (false), preserving any
; user-defined custom chars. Delegates to the shared, tested pure function.
_HS_DelimSetAll(Enable) {
	HotstringsSetWordDelimiters(HSE_TerminatorSetAllString(HotstringsGetWordDelimiters(), Enable))
	TrayTip(t("hs_config.notify_delimiters_saved"), "", "Iconi Mute")
}

; Reset all delimiters to the built-in defaults.
_HS_DelimReset() {
	global HOTSTRINGS_DEFAULT_WORD_DELIMITERS
	HotstringsSetWordDelimiters(HOTSTRINGS_DEFAULT_WORD_DELIMITERS)
	TrayTip(t("hs_config.notify_delimiters_saved"), "", "Iconi Mute")
}

; Mini GUI: one-shot dialog to pick a delimiter character and its consume mode.
; Returns "" on cancel, or triggers the add immediately.
_HS_DelimAddCustom() {
	G := Gui("+AlwaysOnTop +Owner", t("dialog.hotstrings.new_delimiter_title"))
	G.SetFont("s10", "Segoe UI")
	G.Add("Text", "xm y10 w300", t("dialog.hotstrings.new_delimiter_prompt"))
	EditCtrl := G.Add("Edit", "xm y+6 w60 Limit1")
	ChkCtrl  := G.Add("Checkbox", "xm y+10 w300", t("dialog.hotstrings.consume_checkbox"))
	G.Add("Text", "xm y+14 w300 h1 0x10")  ; horizontal rule
	BtnOK := G.Add("Button", "xm y+10 w80 Default", t("button.ok"))

	; Result holder — set by OK handler, read after WaitClose
	Result := { Char: "", Consume: false, OK: false }

	BtnOK.OnEvent("Click", (*) => _HS_DelimGuiSubmit(G, EditCtrl, ChkCtrl, Result))
	G.OnEvent("Close", (*) => G.Destroy())
	G.OnEvent("Escape", (*) => G.Destroy())

	G.Show("Center AutoSize")
	; Block until the GUI is closed (OK or Cancel)
	WinWaitClose("ahk_id " . G.Hwnd)

	if (!Result.OK or Result.Char == "") {
		return
	}
	Ch      := Result.Char
	Current := HotstringsGetWordDelimiters()
	if (InStr(Current, Ch) > 0) {
		return  ; Already present — silently ignore
	}
	HotstringsSetWordDelimiters(Current . Ch)
	if (Result.Consume) {
		Consumed := HotstringsGetConsumedDelimiters()
		if (!InStr(Consumed, Ch)) {
			HotstringsSetConsumedDelimiters(Consumed . Ch)
		}
	}
	TrayTip(t("hs_config.notify_delimiters_saved"), "", "Iconi Mute")
}

; Called by the OK button of the add-delimiter GUI.
_HS_DelimGuiSubmit(G, EditCtrl, ChkCtrl, Result) {
	Ch := EditCtrl.Value
	if (StrLen(Ch) != 1) {
		MsgBox(t("dialog.hotstrings.invalid_body"), t("dialog.hotstrings.invalid_title"), "Icon!")
		return
	}
	Result.Char    := Ch
	Result.Consume := (ChkCtrl.Value == 1)
	Result.OK      := true
	G.Destroy()
}

; Confirm then remove a custom delimiter character (and its consume flag if set).
_HS_DelimRemoveCustom(Char) {
	Res := MsgBox(t("dialog.hotstrings.delete_delimiter_body"), t("dialog.hotstrings.delete_delimiter_title"), "YesNo")
	if (Res != "Yes") {
		return
	}
	HotstringsSetWordDelimiters(StrReplace(HotstringsGetWordDelimiters(), Char, ""))
	Consumed := HotstringsGetConsumedDelimiters()
	if (InStr(Consumed, Char)) {
		HotstringsSetConsumedDelimiters(StrReplace(Consumed, Char, ""))
	}
	TrayTip(t("hs_config.notify_delimiters_saved"), "", "Iconi Mute")
}

; Dynamic handler: standard hotstring categories.
_HS_CategoriesStandard(M, _Cat) {
	global HotstringCategoriesStd, SubMenus
	IsGated := IsCategoryGated("Hotstrings")
	; Section header is rendered by the manifest (section_header type), so we
	; only add the actual category submenus here. The standard + dynamic grand
	; total is computed once by _HS_ComputeGrandTotal for the menu title —
	; summing it again here was dead work (the result was never read).
	for _, Category in HotstringCategoriesStd {
		if !SubMenus.Has(Category)
			continue
		; Count: enabled sections only, and 0 when the Hotstrings master or this
		; category's gate is off — the label shows active hotstrings, never the
		; full "what would reactivate" count.
		Total := _HS_GatedCount(IsGated and IsCategoryGated(Category), _CountEnabledForCategory(Category))
		Title := GetCategoryTitle(Category) . " (" . FmtCount(Total) . ")"
		M.Add(Title, SubMenus[Category])
		; Checkmark follows the category's own enable toggle, not whether every
		; section is checked: the category stays checked with its button on even
		; if some or all sections inside are off.
		if IsGated and IsCategoryGated(Category)
			M.Check(Title)
	}
}

; Dynamic handler: dynamic hotstrings category.
_HS_CategoriesDynamic(M, _Cat) {
	global SubMenus, Features
	if !Features.Has("hotstrings") or !Features["hotstrings"].Has("dynamic")
		return
	if !SubMenus.Has("DynamicHotstrings")
		return
	IsGated := IsCategoryGated("Hotstrings")
	DynMenu := SubMenus["DynamicHotstrings"]
	DynEnabled := 0
	for DKey, DCfg in Features["hotstrings"]["dynamic"] {
		if (IsObject(DCfg) and DCfg.Has("enabled") and DCfg["enabled"])
			DynEnabled += CountDynamicSection(DKey)
	}
	; Active count only: 0 when the Hotstrings master is off (the DynamicHotstrings
	; sub-tree has no separate gate, so it follows the master directly).
	DynTotal := _HS_GatedCount(IsGated, DynEnabled)
	DynTitle := GetCategoryTitle("DynamicHotstrings") . " (" . FmtCount(DynTotal) . ")"
	M.Add(DynTitle, DynMenu)
	DynAllEnabled := true
	DynCount := 0
	for _, DCfg2 in Features["hotstrings"]["dynamic"] {
		DynCount++
		if (IsObject(DCfg2) and DCfg2.Has("enabled") and !DCfg2["enabled"])
			DynAllEnabled := false
	}
	if IsGated and DynAllEnabled and DynCount > 0
		M.Check(DynTitle)
}

; Dynamic handler: Ergopti-specific hotstring categories.
_HS_CategoriesErgopti(M, _Cat) {
	global HotstringCategoriesErgopti, SubMenus
	IsGated := IsCategoryGated("Hotstrings")
	for _, Category in HotstringCategoriesErgopti {
		if !SubMenus.Has(Category)
			continue
		; Count + checkmark: same rule as the standard categories — enabled
		; sections only, 0 when the master or this category's gate is off; the
		; checkmark follows the category's own toggle, not its section states.
		Total := _HS_GatedCount(IsGated and IsCategoryGated(Category), _CountEnabledForCategory(Category))
		Title := GetCategoryTitle(Category) . " (" . FmtCount(Total) . ")"
		M.Add(Title, SubMenus[Category])
		if IsGated and IsCategoryGated(Category)
			M.Check(Title)
	}
}

; Dynamic handler: personal hotstrings (personal_hotstrings.toml + ext tree).
global _PersonalExtTree := Map()
global _ExtTotalPersonalCounterGlobal := { value: 0 }
global _HS_PreScanPersonalCacheLoaded := false
global _HS_ExtensionsCacheLoaded := false
global _HS_ExtensionsCache := []

; Hard cap on how deep the recursive ext-toml scan descends. The scanned tree is
; a user-writable folder, so a directory junction/symlink pointing at an ancestor
; would make a naive recursion loop forever — AHK has no tail-call optimisation,
; so that ends in a fatal stack-overflow-class error that takes down the (often
; deferred, Critical) menu build. 16 levels is far deeper than any real personal
; hotstrings layout; past it we stop descending and warn.
global _HS_SCAN_MAX_DEPTH := 16

; Pre-scans the personal hotstrings directory to build the tree and sum counts
; so they are available for menu labels and the grand total at build time.
_HS_PreScanPersonal() {
	global ScriptInformation, _PersonalExtTree, _ExtTotalPersonalCounterGlobal, _HS_PreScanPersonalCacheLoaded
	if _HS_PreScanPersonalCacheLoaded
		return

	_PersonalExtTree := Map()
	_ExtTotalPersonalCounterGlobal.value := 0

	if !IsSet(ScriptInformation) or !ScriptInformation.Has("PersonalHotstringsDir")
		return

	HsDir := ScriptInformation["PersonalHotstringsDir"]
	if !DirExist(HsDir)
		return

	; ``Depth`` caps descent and ``Visited`` is a set of canonical (lowercased)
	; absolute directory paths already entered — together they guarantee the walk
	; terminates even on a junction/symlink cycle in the user's folder.
	_HS_ScanExt(CurrentDir, PathParts, Depth, Visited) {
		global _HS_SCAN_MAX_DEPTH
		if (Depth > _HS_SCAN_MAX_DEPTH) {
			try LoggerWarn("Hotstrings", "Personal ext scan hit max depth {1} at '{2}' — not descending further (directory cycle?).", _HS_SCAN_MAX_DEPTH, CurrentDir)
			return
		}
		; Canonicalise so two spellings of the same directory collapse to one key;
		; a re-visit means we are inside a cycle and must stop.
		Canonical := StrLower(RegExReplace(CurrentDir, "[/\\]+$"))
		if Visited.Has(Canonical) {
			try LoggerWarn("Hotstrings", "Personal ext scan revisited '{1}' — skipping to break a directory cycle.", CurrentDir)
			return
		}
		Visited[Canonical] := true
		Loop Files CurrentDir . "\*", "DF" {
			if (A_LoopFileAttrib ~= "D") {
				NewParts := PathParts.Clone()
				NewParts.Push(A_LoopFileName)
				_HS_ScanExt(A_LoopFileFullPath, NewParts, Depth + 1, Visited)
			} else if (A_LoopFileName ~= "i)\.toml$") {
				if (PathParts.Length == 0 and A_LoopFileName == "personal_hotstrings.toml")
					continue
				SplitPath A_LoopFileFullPath, , , , &ExtStem
				FileSections := _ParseExtTomlSections(A_LoopFileFullPath)
				FileCount := 0
				for _, FS in FileSections
					FileCount += FS["count"]
				Node := _HS_GetOrCreateNode(_PersonalExtTree, PathParts)
				Node["tomls"].Push({ path: A_LoopFileFullPath, stem: ExtStem, sections: FileSections, count: FileCount })
				_ExtTotalPersonalCounterGlobal.value += FileCount
			}
		}
	}
	; Wrap the whole walk: a runaway/failed scan must degrade to "no extension
	; hotstrings" rather than crash the (often deferred, Critical) menu build.
	try {
		_HS_ScanExt(RegExReplace(HsDir, "[/\\]+$"), [], 1, Map())
	} catch as Err {
		try LoggerError("Hotstrings", "Personal ext scan failed ({1}) — degrading to no extension hotstrings.", Err.Message)
		_PersonalExtTree := Map()
		_ExtTotalPersonalCounterGlobal.value := 0
	}
	_HS_PreScanPersonalCacheLoaded := true
}

_HS_InvalidatePersonalCache() {
	global _HS_PreScanPersonalCacheLoaded, _ParseExtTomlSectionsCache, _HS_ExtensionsCacheLoaded
	_HS_PreScanPersonalCacheLoaded := false
	_ParseExtTomlSectionsCache := Map()
	_HS_ExtensionsCacheLoaded := false
}

; Pre-scans the bundled extensions directory to build the extension data
; so it is available for menu labels without doing file I/O under Critical.
_HS_PreScanExtensions() {
	global _ExtensionsDir, _HS_ExtensionsCacheLoaded, _HS_ExtensionsCache
	if _HS_ExtensionsCacheLoaded
		return
	ExtensionsBaseDir := _ExtensionsDir . "\"
	_HS_ExtensionsCache := []
	if DirExist(ExtensionsBaseDir) {
		Loop Files ExtensionsBaseDir . "*", "D" {
			ExtId          := A_LoopFileName
			ExtDir         := A_LoopFileFullPath
			ManifestPath   := ExtDir . "\manifest.toml"
			ExtDisplayName := ExtId
			if FileExist(ManifestPath) {
				try {
					MC := FileRead(ManifestPath, "UTF-8")
					if RegExMatch(MC, "name\s*=\s*" . Chr(34) . "([^" . Chr(34) . "]+)" . Chr(34), &NM)
						ExtDisplayName := NM[1]
				}
			}
			HsDir     := ExtDir . "\hotstrings\"
			TomlFiles := []
			if DirExist(HsDir) {
				Loop Files HsDir . "*.toml" {
					FileSections := _ParseExtTomlSections(A_LoopFileFullPath)
					FileCount := 0
					for _, FS in FileSections
						FileCount += FS["count"]
					SplitPath A_LoopFileFullPath, , , , &FileStem
					TomlFiles.Push({ path: A_LoopFileFullPath, stem: FileStem
						, sections: FileSections, count: FileCount })
				}
			}
			_HS_ExtensionsCache.Push({ id: ExtId, name: ExtDisplayName, toml_files: TomlFiles })
		}
	}
	_HS_ExtensionsCacheLoaded := true
}

_HS_GetOrCreateNode(Root, PathParts) {
	Tree := Root
	Node := false
	for _, Part in PathParts {
		if !Tree.Has(Part)
			Tree[Part] := Map("subfolders", Map(), "tomls", [])
		Node := Tree[Part]
		Tree := Node["subfolders"]
	}
	if (Node == false) {
		if !Root.Has("")
			Root[""] := Map("subfolders", Map(), "tomls", [])
		return Root[""]
	}
	return Node
}

; Dynamic handler: personal hotstrings (personal_hotstrings.toml + pre-scanned ext tree).
_HS_Personal(M, _Cat) {
	global ScriptInformation, Features, _PersonalExtTree
	IsGated := IsCategoryGated("Hotstrings")
	PersonalTomlData := false
	PersonalTomlPath := IsSet(ScriptInformation) ? ScriptInformation.Get("PersonalTomlPath", "") : ""
	if (PersonalTomlPath != "" and FileExist(PersonalTomlPath)) {
		PersonalTomlData := ReadPersonalToml()
	}

	if (PersonalTomlData != false) {
		TomlData := PersonalTomlData
		; Two sections with an identical user-typed description would otherwise
		; produce identical menu labels, and AHK's name-based Menu.Check/Uncheck
		; always resolves to the FIRST match — toggling/selecting the SECOND
		; section silently painted the checkmark on the FIRST
		; (duplicate-personal-section-desc-menu-mistarget). Every Check/Uncheck-
		; relevant label below is built from this map instead of the raw
		; (possibly-duplicate) description.
		DisambiguatedLabels := _HS_BuildDisambiguatedSectionLabels(TomlData)
		PersonalMenu := Menu()
		RegisterMenuItem(PersonalMenu, t("menu.hotstrings.open_editor"), (*) => OpenPersonalEditor())
		RegisterMenuItem(PersonalMenu, t("menu.hotstrings.open_file"), _MakeOpenFileFn(PersonalTomlPath))
		PersonalMenu.Add()
		ShortcutLabel := t("menu.hotstrings.shortcut_prefix") . ScriptInformation["MagicKey"]
		PersonalMenu.Add(ShortcutLabel, (*) => NoAction())
		PersonalMenu.Disable(ShortcutLabel)
		CurDefaultSec := _EditorPrefGet("DefaultSection", "")
		DefaultSectionMenu := Menu()
		RegisterMenuItem(DefaultSectionMenu, t("menu.hotstrings.default_none"),
			(*) => _SetPersonalDefaultSection("", PersonalMenu, TomlData, DefaultSectionMenu, DisambiguatedLabels))
		if (CurDefaultSec == "")
			DefaultSectionMenu.Check(t("menu.hotstrings.default_none"))
		DefaultSectionMenu.Add()
		for _, SecName in TomlData["sections_order"] {
			if (SecName == "-")
				continue
			if !TomlData["sections"].Has(SecName)
				continue
			SecLabel := DisambiguatedLabels[SecName]
			RegisterMenuItem(DefaultSectionMenu, SecLabel,
				_MakeSetDefaultSectionFn(SecName, PersonalMenu, TomlData, DefaultSectionMenu, DisambiguatedLabels))
			if (CurDefaultSec == SecName)
				DefaultSectionMenu.Check(SecLabel)
		}
		CurDefaultLabel := (CurDefaultSec == "") ? t("menu.hotstrings.default_none")
			: (DisambiguatedLabels.Has(CurDefaultSec) ? DisambiguatedLabels[CurDefaultSec] : CurDefaultSec)
		global _PrevDefaultLabel := CurDefaultLabel
		PersonalMenu.Add(t("menu.hotstrings.default_category_prefix") . CurDefaultLabel, DefaultSectionMenu)
		CloseOnAddLabel := t("menu.hotstrings.close_on_add")
		RegisterMenuItem(PersonalMenu, CloseOnAddLabel, (*) => _TogglePersonalCloseOnAdd(PersonalMenu))
		if (_EditorPrefGet("close_on_add", "1") == "1")
			PersonalMenu.Check(CloseOnAddLabel)
		if (TomlData["sections_order"].Length > 0) {
			PersonalMenu.Add()
			; Section-level bulk actions for the personal hotstrings.
			RegisterMenuItem(PersonalMenu, t("menu.hotstrings.enable_all"),  (*) => HS_TogglePersonalAllSections(true))
			RegisterMenuItem(PersonalMenu, t("menu.hotstrings.disable_all"), (*) => HS_TogglePersonalAllSections(false))
			PersonalMenu.Add()
			for _, SecName in TomlData["sections_order"] {
				if (SecName == "-") {
					PersonalMenu.Add()
					continue
				}
				if !TomlData["sections"].Has(SecName)
					continue
				SecData  := TomlData["sections"][SecName]
				SecLabel := DisambiguatedLabels[SecName] . " (" . FmtCount(SecData["entries"].Length) . ")"
				; v2 path for a runtime-discovered personal section: the Features
				; node (and config.toml section) key the lowercased TOML section name.
				MenuAddItemWithLabel(PersonalMenu, "hotstrings.personal." . StrLower(SecName), SecLabel, "Hotstrings")
			}
		}
		PersonalActiveCount := 0
		PersonalAllEnabled  := true
		PersonalSectionCount := 0
		for _, SecName2 in TomlData["sections_order"] {
			if (SecName2 == "-" or !TomlData["sections"].Has(SecName2))
				continue
			PersonalSectionCount++
			PV2Id    := StrLower(SecName2)
			PEnabled := Features["hotstrings"].Has("personal")
				and Features["hotstrings"]["personal"].Has(PV2Id)
				and (Features["hotstrings"]["personal"][PV2Id] is Map) and Features["hotstrings"]["personal"][PV2Id].Has("enabled") and Features["hotstrings"]["personal"][PV2Id]["enabled"]
			if PEnabled
				PersonalActiveCount += TomlData["sections"][SecName2]["entries"].Length
			else
				PersonalAllEnabled := false
		}
		PersonalTitle := GetCategoryTitle("Personal") . " (" . FmtCount(PersonalActiveCount) . ")"
		M.Add(PersonalTitle, PersonalMenu)
		if IsGated and PersonalAllEnabled and PersonalSectionCount > 0
			M.Check(PersonalTitle)
	}

	RootNode := false
	TreeCopy := _PersonalExtTree.Clone()
	if TreeCopy.Has("") {
		RootNode := TreeCopy[""]
		TreeCopy.Delete("")
	}
	_HS_RenderTree(TreeCopy, M)
	if (RootNode != false) {
		FileNodeList := RootNode["tomls"]
		loop FileNodeList.Length {
			i := A_Index
			loop FileNodeList.Length - i {
				j := A_Index
				if (StrCompare(FileNodeList[j].stem, FileNodeList[j+1].stem) > 0) {
					tmp := FileNodeList[j]
					FileNodeList[j] := FileNodeList[j+1]
					FileNodeList[j+1] := tmp
				}
			}
		}
		for _, TF in FileNodeList {
			TFMenu := Menu()
			RegisterMenuItem(TFMenu, t("menu.hotstrings.open_file"), _MakeOpenFileFn(TF.path))
			if (TF.sections.Length > 0) {
				TFMenu.Add()
				for _, ES in TF.sections {
					SecLabel := ES["description"] . " (" . FmtCount(ES["count"]) . ")"
					TFMenu.Add(SecLabel, (*) => NoAction())
					TFMenu.Disable(SecLabel)
				}
			}
			M.Add(TF.stem . (TF.count > 0 ? " (" . FmtCount(TF.count) . ")" : ""), TFMenu)
		}
	}
}

; Sum all hotstring counts inside a node and its sub-nodes recursively.
_HS_NodeTotal(Node) {
	Total := 0
	for _, TF in Node["tomls"]
		Total += TF.count
	for _, Sub in Node["subfolders"]
		Total += _HS_NodeTotal(Sub)
	return Total
}

; Render recursive ext tree (nested folder structure)
_HS_RenderTree(Tree, ParentMenu) {
	FolderNames := []
	for FolderName in Tree
		FolderNames.Push(FolderName)
	loop FolderNames.Length {
		i := A_Index
		loop FolderNames.Length - i {
			j := A_Index
			if (StrCompare(FolderNames[j], FolderNames[j+1]) > 0) {
				tmp := FolderNames[j]
				FolderNames[j] := FolderNames[j+1]
				FolderNames[j+1] := tmp
			}
		}
	}
	for _, FolderName in FolderNames {
		Node := Tree[FolderName]
		FolderMenu := Menu()
		FileNodeList := Node["tomls"]
		loop FileNodeList.Length {
			i := A_Index
			loop FileNodeList.Length - i {
				j := A_Index
				if (StrCompare(FileNodeList[j].stem, FileNodeList[j+1].stem) > 0) {
					tmp := FileNodeList[j]
					FileNodeList[j] := FileNodeList[j+1]
					FileNodeList[j+1] := tmp
				}
			}
		}
		if (Node["subfolders"].Count > 0)
			_HS_RenderTree(Node["subfolders"], FolderMenu)
		if (Node["subfolders"].Count > 0 and FileNodeList.Length > 0)
			FolderMenu.Add()
		for _, TF in FileNodeList {
			TFMenu := Menu()
			RegisterMenuItem(TFMenu, t("menu.hotstrings.open_file"), _MakeOpenFileFn(TF.path))
			if (TF.sections.Length > 0) {
				TFMenu.Add()
				for _, ES in TF.sections {
					SecLabel := ES["description"] . " (" . FmtCount(ES["count"]) . ")"
					TFMenu.Add(SecLabel, (*) => NoAction())
					TFMenu.Disable(SecLabel)
				}
			}
			FolderMenu.Add(TF.stem . (TF.count > 0 ? " (" . FmtCount(TF.count) . ")" : ""), TFMenu)
		}
		FolderTotal := _HS_NodeTotal(Node)
		FolderLabel := FolderName . (FolderTotal > 0 ? " (" . FmtCount(FolderTotal) . ")" : "")
		ParentMenu.Add(FolderLabel, FolderMenu)
	}
}

; Dynamic handler: bundled extension hotstrings.
_HS_Extensions(M, _Cat) {
	global _HS_ExtensionsCache
	; Use the pre-warmed cache so menu build never does file I/O here — the heavy
	; DirExist/Loop Files/FileRead scan runs in _HS_PreScanExtensions off-Critical.
	_HS_PreScanExtensions()
	BundledExtensions := _HS_ExtensionsCache
	if (BundledExtensions.Length == 0) {
		EmptyLabel := t("menu.extensions.empty")
		M.Add(EmptyLabel, (*) => NoAction())
		M.Disable(EmptyLabel)
	} else {
		for _, Ext in BundledExtensions {
			ExtHsMenu    := Menu()
			ExtTotalForExt := 0
			for _, TF in Ext.toml_files
				ExtTotalForExt += TF.count
			if (Ext.toml_files.Length == 0) {
				NoHsLabel := t("menu.extensions.empty")
				ExtHsMenu.Add(NoHsLabel, (*) => NoAction())
				ExtHsMenu.Disable(NoHsLabel)
			} else {
				for _, TF in Ext.toml_files {
					TFMenu := Menu()
					RegisterMenuItem(TFMenu, t("menu.hotstrings.open_file"), _MakeOpenFileFn(TF.path))
					if (TF.sections.Length == 0) {
						TFMenu.Add()
						NoSecLabel := t("menu.extensions.empty")
						TFMenu.Add(NoSecLabel, (*) => NoAction())
						TFMenu.Disable(NoSecLabel)
					} else {
						TFMenu.Add()
						for _, Sec in TF.sections {
							SecLabel := Sec["description"] . " (" . FmtCount(Sec["count"]) . ")"
							TFMenu.Add(SecLabel, (*) => NoAction())
							TFMenu.Disable(SecLabel)
						}
					}
					TFTitle := TF.stem . (TF.count > 0 ? " (" . FmtCount(TF.count) . ")" : "")
					ExtHsMenu.Add(TFTitle, TFMenu)
				}
			}
			M.Add(Ext.name . (ExtTotalForExt > 0 ? " (" . FmtCount(ExtTotalForExt) . ")" : ""), ExtHsMenu)
		}
	}
}


