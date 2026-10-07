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

; The hotstrings_menu scope rows, bound to the compensated scope owner.
_HS_ScopeCommands(Options := unset) {
	OwnedOptions := IsSet(Options) ? Options : Map()
	return Map(
		"scope_restore", (*) => HotstringsScopeApply("recommended", OwnedOptions),
		"scope_clear", (*) => HotstringsScopeApply("clear", OwnedOptions))
}

; Compute the grand total count used in the tray menu title label.
; Sums enabled standard, ergopti, dynamic, personal and extension entries.
_HS_ComputeGrandTotal() {
global Features, HotstringCategoriesStd, HotstringCategoriesErgopti
global ScriptInformation, _ExtTotalPersonalCounterGlobal, _HS_GrandTotalCache, _HotstringExtensionPacks
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
for _, Pack in HotstringsLanguageCategories() {
	for _, LangCat in Pack["categories"]
		Total += _CountEnabledForCategory(LangCat["v1"])
}
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
Total += PersonalFileControls.ActiveCount()
Total += HotstringExtensions_Count(Features, _HotstringExtensionPacks, IsCategoryGated("Hotstrings"))
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
; List provider: the magic-key row. `type = "list"` since 2026-08-07, so this
; returns row DATA and the renderer builds the item — the row was built three
; times before that, once per driver, from a declaration that named only the slot.
_HS_MagicKeyRows() {
	return [Map(
		"label",  t("menu.hotstrings.magic_key_prefix") . ScriptInformation["MagicKey"],
		"action", MagicKeyEditor
	)]
}

; Dynamic handler: whole-tree bulk actions (force every hotstring section on/off).
; Rendered inside the "⚙️ Paramètres hotstrings" group, just after its separator.

; Dynamic handler: delays & colours sub-menu. Mirrors the Hammerspoon "delays"
; submenu — the per-category config window, then quick-access per-delay items
; grouped by a separator, exactly like the HS make_delay_item rows: the base
; default expansion delay, then the ★ magic-key and autocorrection per-category
; delays (settable straight from the menu, not only buried in the config window).
; `list` since 2026-08-07: the row itself is the renderer's, and the submenu
; hanging off it stays a native Menu this function owns and hands over — the same
; `submenu` shape the category blocks use while their trees are still built here.
_HS_DelaysColorsRows(OpenConfigFn := OpenHotstringsConfigWindow) {
	global UI_LLM_TIMEOUT_SEC, DYN_HOTSTRINGS_DEFAULT_DELAY
	; Nested row DATA since 2026-08-07. This was a native Menu handed over in
	; `submenu`, so the whole submenu was assembled here; none of these rows
	; mutates the live menu — each opens a prompt and the tray rebuilds after —
	; so nothing held them back.
	Sub := [
		MenuRenderer_CommandRow("hotstrings_delays_menu", "hotstrings_config_window",
			Map("hotstrings_config_window", (*) => OpenConfigFn.Call()), Map("hotstrings_config_ready", (*) => true)),
		Map("separator", true),
		Map("label", _HS_DefaultDelayLabel(), "action", (*) => _HS_PromptDefaultDelay()),
		Map("label", _HS_CategoryDelayLabel("magickey", "menu.hotstrings.delay_magic_key"),
			"action", (*) => _HS_PromptCategoryDelay("magickey", "menu.hotstrings.delay_magic_key")),
		Map("label", _HS_CategoryDelayLabel("autocorrection", "menu.hotstrings.delay_autocorrection"),
			"action", (*) => _HS_PromptCategoryDelay("autocorrection", "menu.hotstrings.delay_autocorrection")),
		Map("separator", true),
		; AI prediction tooltip auto-dismiss timeout — mirrors the HS "Délai
		; d'acceptation IA" item. No TOML [_meta] delay backs the "llm_prediction"
		; key, so its no-override default is the UI constant (20 s); the live
		; tooltip timer reads the same override (infra/tooltip.ahk).
		Map("label", _HS_CategoryDelayLabel("llm_prediction", "menu.hotstrings.tooltip_ai_acceptance", UI_LLM_TIMEOUT_SEC),
			"action", (*) => _HS_PromptCategoryDelay("llm_prediction", "menu.hotstrings.tooltip_ai_acceptance", UI_LLM_TIMEOUT_SEC)),
		; Dynamic hotstrings (dates, phone/SSN/IBAN prefixes) activation delay —
		; mirrors the HS "Délai autocomplétion" item. Backed by the
		; "dynamichotstrings" override; the no-override default is
		; DYN_HOTSTRINGS_DEFAULT_DELAY (2 s).
		Map("label", _HS_CategoryDelayLabel("dynamichotstrings", "menu.hotstrings.tooltip_autocompletion", DYN_HOTSTRINGS_DEFAULT_DELAY),
			"action", (*) => _HS_PromptCategoryDelay("dynamichotstrings", "menu.hotstrings.tooltip_autocompletion", DYN_HOTSTRINGS_DEFAULT_DELAY))
	]
	return [Map(
		"label", t("menu.hotstrings.delays_colors"),
		"items", Sub)]
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
	IB := Ui_InputBox(t("menu.hotstrings.delay_prompt"), t("menu.hotstrings.tooltip_default"), "w340 h140", CurMs)
	if (IB.Result != "OK") {
		return
	}
	Val := Trim(IB.Value, " `t")
	if !RegExMatch(Val, "^\d+$") {
		Ui_MsgBox(t("menu.hotstrings.delay_invalid_body"), t("menu.hotstrings.delay_invalid_title"))
		return
	}
	return _HS_CommitDelayOverride("_global", (Val + 0) / 1000)
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
	IB := Ui_InputBox(t("menu.hotstrings.delay_prompt"), t(I18nKey), "w340 h140", CurMs)
	if (IB.Result != "OK") {
		return
	}
	Val := Trim(IB.Value, " `t")
	if !RegExMatch(Val, "^\d+$") {
		Ui_MsgBox(t("menu.hotstrings.delay_invalid_body"), t("menu.hotstrings.delay_invalid_title"))
		return
	}
	return _HS_CommitDelayOverride(Cat, (Val + 0) / 1000)
}

; Persist first and rebuild only after a strict successful result. The injected
; seams keep the menu's failure ordering behaviour-testable without opening an
; InputBox or registering real hotstrings.
_HS_CommitDelayOverride(Cat, Value, SetterFn := 0, RebuildFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		; Persistence and live hotstring registration may call filesystem/native
		; adapters. Keep the complete menu action interruptible.
		Critical("Off")
		try return _HS_CommitDelayOverride(Cat, Value, SetterFn, RebuildFn)
		finally Critical(InheritedCritical)
	}
	try Committed := HasMethod(SetterFn, "Call")
		? SetterFn.Call(Cat, "", "delay", Value)
		: HotstringsSetOverride(Cat, "", "delay", Value)
	catch as Err {
		try LoggerError("HotstringsMenu",
			"Failed to persist the '{1}' delay override: {2}.", Cat, Err.Message)
		return false
	}
	if !(Committed is Integer) || Committed != 1
		return false

	; Delays are baked into specs at registration time, so the durable value must
	; be re-registered live. A refused writer must never rebuild from stale RAM.
	try {
		if HasMethod(RebuildFn, "Call")
			Rebuilt := RebuildFn.Call()
		else
			Rebuilt := RebuildHotstringsLive()
	} catch as Err {
		try LoggerError("HotstringsMenu",
			"Delay override for '{1}' was persisted but live rebuild failed: {2}.",
			Cat, Err.Message)
		return false
	}
	if !(Rebuilt is Integer) || Rebuilt != 1 {
		try LoggerError("HotstringsMenu",
			"Delay override for '{1}' was persisted but live rebuild was refused.",
			Cat)
		return false
	}
	return true
}

; List provider: the word-expanders sub-menu, as ROWS.
;
; Returns data rather than a Menu so the shared renderer materialises every row.
; The three drivers each rebuilt this submenu with the same logic and their own
; row API; the manifest declares it `type = "list"` now and each one answers with
; the same {label, action, checked, items} shape.
_HS_WordExpanderRows(Commands := unset) {
	global HSE_Terminators, _HotstringsTerminatorRecords
	Current      := HotstringsGetWordDelimiters()
	Consumed     := HotstringsGetConsumedDelimiters()
	Defs         := HSE_Terminators.all()
	BuiltinChars := HSE_TerminatorBuiltinChars()

	Rows := []

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
	RecordChars := ""
	if _HotstringsTerminatorRecords is Object {
		for Record in _HotstringsTerminatorRecords.Records {
			RecordChars .= Record.Char
			Rows.Push(Map("label", Record.Label
				. (Record.Consume ? " " . t("menu.hotstrings.consumed_suffix") : ""),
				"checked", Record.Enabled,
				"items", [Map("label", Record.Label, "checked", Record.Enabled,
					"action", ((Key, Enabled) => (*) => _HS_DelimRecordState(Key, !Enabled))(Record.Key, Record.Enabled)),
					MenuRenderer_CommandRow("word_expander_custom_menu", "word_expander_delete",
					Map("word_expander_delete", ((Key) => (*) => _HS_DelimRemoveRecord(Key))(Record.Key)),
					Map("word_expanders_ready", (*) => !A_IsSuspended))]))
		}
	}
	Loop Parse, Current {
		Ch := A_LoopField
		if (Ch == "`r" or Ch == "`n" or InStr(BuiltinChars, Ch) or InStr(RecordChars, Ch))
			continue
		ConsumedSfx := (InStr(Consumed, Ch) > 0) ? (" " . t("menu.hotstrings.consumed_suffix")) : ""
		Rows.Push(Map(
			"label", Ch . " : " . t("menu.hotstrings.custom_label") . ConsumedSfx,
			; Always ticked: a custom delimiter exists only while it is in the
			; active string, so its presence IS its enabled state.
			"checked", true,
			"items", [MenuRenderer_CommandRow("word_expander_custom_menu", "word_expander_delete",
				Map("word_expander_delete", ((C) => (*) => _HS_DelimRemoveCustom(C))(Ch)),
				Map("word_expanders_ready", (*) => !A_IsSuspended))]))
	}

	Rows.Push(MenuRenderer_CommandRow("word_expander_custom_menu", "word_expander_add",
		Map("word_expander_add", (*) => _HS_DelimAddCustom()),
		Map("word_expanders_ready", (*) => !A_IsSuspended)))

	if !IsSet(Commands) {
		Commands := Map(
			"word_expanders_enable_all", (*) => _HS_DelimSetAll(true),
			"word_expanders_disable_all", (*) => _HS_DelimSetAll(false),
			"word_expanders_restore", (*) => _HS_DelimReset())
	}
	Ready := (*) => !A_IsSuspended
	GuardedCommands := Map()
	for Id, Command in Commands
		GuardedCommands[Id] := _HS_WordExpanderCommand.Bind(Command, Ready)
	Submenu := MenuRenderer_Build("word_expanders_menu", "HotstringsParams", Map(), Map(),
		Map("word_expander_entries", (*) => Rows), GuardedCommands,
		Map("word_expanders_ready", Ready))
	return [Map("label", t("menu.hotstrings.word_expanders"), "submenu", Submenu)]
}

; A native menu can outlive the pause state under which it was rendered. The
; same current-readiness owner draws the row and admits its delayed delivery.
_HS_WordExpanderCommand(Command, Ready, *) {
	if !Ready.Call()
		return false
	return Command.Call()
}

; Toggle a whole catalogue entry (all of its chars) on/off and persist. The
; toggle logic lives in HSE_TerminatorToggleString (infra/hotstrings_config.ahk)
; so it is shared with the config window and unit-tested.
_HS_DelimToggleEntry(CharsArr, WriterFn := 0, ReplaceFn := 0, NotifyFn := 0) {
	BuildFn := (CurrentWord, CurrentConsumed) => {
		Word: HSE_TerminatorToggleString(CurrentWord, CharsArr),
		Consumed: CurrentConsumed
	}
	return _HS_DelimCommit(BuildFn, WriterFn, ReplaceFn, NotifyFn)
}

; Set every built-in catalogue entry on (true) or off (false), preserving any
; user-defined custom chars. Delegates to the shared, tested pure function.
_HS_DelimSetAll(Enable, WriterFn := 0, ReplaceFn := 0, NotifyFn := 0) {
	BuildFn := (CurrentWord, CurrentConsumed) => {
		Word: HSE_TerminatorSetAllString(CurrentWord, Enable),
		Consumed: CurrentConsumed
	}
	return _HS_DelimCommit(BuildFn, WriterFn, ReplaceFn, NotifyFn)
}

; Restore shipped defaults without deleting personal word or consumed markers.
_HS_DelimReset(WriterFn := 0, ReplaceFn := 0, NotifyFn := 0) {
	BuildFn := (CurrentWord, CurrentConsumed) =>
		HSE_TerminatorRestoreDefaults(CurrentWord, CurrentConsumed)
	return _HS_DelimCommit(BuildFn, WriterFn, ReplaceFn, NotifyFn)
}

; Execute one delimiter candidate transaction and show the success notice only
; after strict durable success. A terminal transition or refused writer leaves
; both engine variables untouched and produces no misleading notification.
_HS_DelimCommit(BuildFn, WriterFn := 0, ReplaceFn := 0, NotifyFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _HS_DelimCommit(BuildFn, WriterFn, ReplaceFn, NotifyFn)
		finally Critical(InheritedCritical)
	}
	try Committed := HotstringsCommitDelimiterUpdate(BuildFn, WriterFn, ReplaceFn)
	catch as Err {
		try LoggerError("HotstringsMenu",
			"Delimiter transaction raised before publication: {1}.", Err.Message)
		return false
	}
	if !(Committed is Integer) || Committed != 1
		return false

	try {
		Message := t("hs_config.notify_delimiters_saved")
		if HasMethod(NotifyFn, "Call")
			NotifyFn.Call(Message, "", "Iconi Mute")
		else
			TrayTip(Message, "", "Iconi Mute")
	} catch as Err {
		; The durable mutation already succeeded; confine a notifier failure so a
		; tray callback cannot escape through AHK's menu dispatcher.
		try LoggerError("HotstringsMenu",
			"Delimiter settings were saved but the success notification failed: {1}.",
			Err.Message)
	}
	return true
}

; The open add-delimiter dialog, "" when none is open.
global _HS_DelimAddGui := ""

; Mini GUI: one-shot dialog to pick a delimiter character and its consume mode.
; Returns "" on cancel, or triggers the add immediately. It is an unowned
; window with its own taskbar entry: an owned window has none, so once another
; app covered it the dialog this thread waits on could not be reached again.
_HS_DelimAddCustom() {
	global _HS_DelimAddGui
	if A_IsSuspended
		return false
	if IsObject(_HS_DelimAddGui) {
		; Requested again: bring the open dialog back instead of stacking a
		; second one over it.
		WMPresentWindow(_HS_DelimAddGui)
		return
	}
	G := Gui_Create("", t("dialog.hotstrings.new_delimiter_title"))
	G.SetFont("s10", "Segoe UI")
	G.Add("Text", "xm y10 w300", t("dialog.hotstrings.new_delimiter_prompt"))
	EditCtrl := G.Add("Edit", "xm y+6 w60 Limit2")
	ChkCtrl  := G.Add("Checkbox", "xm y+10 w300", t("dialog.hotstrings.consume_checkbox"))
	G.Add("Text", "xm y+14 w300 h1 0x10")  ; horizontal rule
	BtnOK := G.Add("Button", "xm y+10 w80 Default", t("button.ok"))

	; Result holder — set by OK handler, read after WaitClose
	Result := { Char: "", Consume: false, OK: false }

	BtnOK.OnEvent("Click", (*) => _HS_DelimGuiSubmit(G, EditCtrl, ChkCtrl, Result))
	G.OnEvent("Close", (*) => G.Destroy())
	G.OnEvent("Escape", (*) => G.Destroy())

	G.Show("Center AutoSize")
	_HS_DelimAddGui := G
	; Block until the GUI is closed (OK or Cancel)
	try WinWaitClose("ahk_id " . G.Hwnd)
	finally _HS_DelimAddGui := ""

	; A held native dialog cannot borrow its pre-pause menu admission.
	if A_IsSuspended
		return false
	if (!Result.OK or Result.Char == "") {
		return false
	}
	return _HS_DelimAddRecordCommit(Result.Char, Result.Consume)
}

; Add the word and optional consumed membership in ONE transaction. The previous
; two-setter sequence could publish the word key while the consumed-key write
; failed, and each setter rebuilt the same whole file from a different snapshot.
_HS_DelimAddCustomCommit(Char, Consume, WriterFn := 0, ReplaceFn := 0,
	NotifyFn := 0) {
	BuildFn := (CurrentWord, CurrentConsumed) => {
		Word: InStr(CurrentWord, Char) ? CurrentWord : CurrentWord . Char,
		Consumed: (Consume && !InStr(CurrentConsumed, Char))
			? CurrentConsumed . Char : CurrentConsumed
	}
	return _HS_DelimCommit(BuildFn, WriterFn, ReplaceFn, NotifyFn)
}

; Called by the OK button of the add-delimiter GUI.
_HS_DelimGuiSubmit(G, EditCtrl, ChkCtrl, Result) {
	Ch := EditCtrl.Value
	if !HotstringsTerminatorRecordCharacter(Ch) {
		Ui_MsgBox(t("dialog.hotstrings.invalid_body"), t("dialog.hotstrings.invalid_title"), "Icon!")
		return
	}
	Result.Char    := Ch
	Result.Consume := (ChkCtrl.Value == 1)
	Result.OK      := true
	G.Destroy()
}

; Confirm then remove a custom delimiter character (and its consume flag if set).
_HS_DelimRemoveCustom(Char) {
	Res := Ui_MsgBox(t("dialog.hotstrings.delete_delimiter_body"), t("dialog.hotstrings.delete_delimiter_title"), "YesNo")
	if (Res != "Yes") {
		return
	}
	return _HS_DelimRemoveCustomCommit(Char)
}

; Remove both memberships from the same admitted snapshot and publish them as a
; single durable candidate.
_HS_DelimRemoveCustomCommit(Char, WriterFn := 0, ReplaceFn := 0,
	NotifyFn := 0) {
	BuildFn := (CurrentWord, CurrentConsumed) => {
		Word: StrReplace(CurrentWord, Char, ""),
		Consumed: StrReplace(CurrentConsumed, Char, "")
	}
	return _HS_DelimCommit(BuildFn, WriterFn, ReplaceFn, NotifyFn)
}

; Dynamic handler: standard hotstring categories.
_HS_CategoryRowsStandard() {
	global HotstringCategoriesStd, SubMenus
	Rows := []
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
		; Checkmark follows the category's own enable toggle, not whether every
		; section is checked: the category stays checked with its button on even
		; if some or all sections inside are off.
		Rows.Push(Map(
			"label",   Title,
			"checked", IsCategoryGated(Category) ? true : false,
			"submenu", SubMenus[Category]))
	}
	return Rows
}

; Dynamic handler: dynamic hotstrings category.
_HS_CategoryRowsDynamic() {
	global SubMenus, Features
	Rows := []
	if !Features.Has("hotstrings") or !Features["hotstrings"].Has("dynamic")
		return Rows
	if !SubMenus.Has("DynamicHotstrings")
		return Rows
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
	DynAllEnabled := true
	DynCount := 0
	for _, DCfg2 in MasterGateDesiredFeatures(Features)["hotstrings"]["dynamic"] {
		DynCount++
		if (IsObject(DCfg2) and DCfg2.Has("enabled") and !DCfg2["enabled"])
			DynAllEnabled := false
	}
	; This function became a `list` provider when the five category blocks moved
	; onto the manifest, and half of it did not follow. It returned an EMPTY array
	; — so the dynamic-hotstrings row was missing from the menu entirely — and it
	; still called `M.Check(DynTitle)` on a menu object a provider is never handed.
	; That reference is an unset local, and it threw straight through
	; MenuRenderer_Build into the deferred tray build's catch, which meant the
	; WHOLE tray vanished, leaving only the submenus that add themselves. Latent
	; until a configuration satisfied the condition guarding it.
	Rows.Push(Map(
		"label",   DynTitle,
		"checked", (DynAllEnabled and DynCount > 0) ? true : false,
		"submenu", DynMenu))
	return Rows
}

; The rows of the bundled categories one extension binds whole (Ergopti's SFB
; reduction and rolls), then of the sections it binds inside a bundled category
; (Ergopti's repeat corrections in the magic key). They keep their historical
; ids, gates and SubMenus, so each row is built like a standard category's or
; section's, under the extension that supplies it (_HotstringBoundSources,
; committed at boot).
; @param {String} ExtensionId - Discovered pack id.
; @returns {Object} { rows: Array of menu rows, total: active hotstring count }.
_HS_BoundCategoryRows(ExtensionId) {
	global HotstringCategoriesStd, HotstringCategoriesErgopti, SubMenus, _HotstringBoundSources
	Result := { rows: [], total: 0 }
	if (_HotstringBoundSources.Count == 0)
		return Result
	IsGated := IsCategoryGated("Hotstrings")
	for _, Categories in [HotstringCategoriesStd, HotstringCategoriesErgopti] {
		for _, Category in Categories {
			Key := StrLower(StrReplace(Category, "_"))
			if !_HotstringBoundSources.Has(Key) || _HotstringBoundSources[Key]["extension"] != ExtensionId
					|| !SubMenus.Has(Category)
				continue
			; Count + checkmark: same rule as the standard categories — enabled
			; sections only, 0 when the master or this category's gate is off; the
			; checkmark follows the category's own toggle, not its section states.
			Total := _HS_GatedCount(IsGated and IsCategoryGated(Category), _CountEnabledForCategory(Category))
			Result.rows.Push(Map(
				"label",   GetCategoryTitle(Category) . " (" . FmtCount(Total) . ")",
				"checked", IsCategoryGated(Category) ? true : false,
				"submenu", SubMenus[Category]))
			Result.total += Total
		}
	}
	_HS_BoundSectionRows(ExtensionId, Result)
	return Result
}

; Appends one row per section the extension binds inside a bundled category,
; built from the section's manifest entry exactly as its category submenu did.
_HS_BoundSectionRows(ExtensionId, Result) {
	global HotstringCategoriesStd, HotstringCategoriesErgopti, _HotstringBoundSources, _LegacyTopCategoryMap
	IsGated := IsCategoryGated("Hotstrings")
	First := true
	for _, Categories in [HotstringCategoriesStd, HotstringCategoriesErgopti] {
		for _, Category in Categories {
			Key := StrLower(StrReplace(Category, "_"))
			if !_HotstringBoundSources.Has(Key) || !_LegacyTopCategoryMap.Has(Category)
				continue
			Owners := _HotstringBoundSources[Key]["section_extensions"]
			for _, Entry in ManifestFeaturesForSection(_LegacyTopCategoryMap[Category]) {
				Parts := StrSplit(Entry["path"], ".")
				Section := Parts[Parts.Length]
				if !Owners.Has(StrLower(Section)) || Owners[StrLower(Section)] != ExtensionId
					continue
				Row := MenuRowFromManifest(Entry, Category)
				if (Row == "")
					continue
				if (First && Result.rows.Length > 0)
					Result.rows.Push(Map("separator", true))
				First := false
				Result.rows.Push(Row)
				if (IsGated && IsCategoryGated(Category) && ReadFeatureStateV2(Entry["path"])["enabled"])
					Result.total += CountTomlSection(Category, Section)
			}
		}
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
global _HS_SCAN_MAX_DEPTH := PersonalFileScanMaxDepth()

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
				if !HS_PersonalDirectoryAdmitted(A_LoopFileFullPath, Depth + 1) {
					_HS_GetOrCreateNode(_PersonalExtTree, NewParts)["unavailable"] := true
					continue
				}
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

; Boot discovery owns the same complete catalogue used by registration. Reading
; that snapshot also keeps menu rendering free of directory I/O under Critical.
_HS_PreScanExtensions() {
	global _HotstringExtensionPacks, _HS_ExtensionsCacheLoaded, _HS_ExtensionsCache
	if _HS_ExtensionsCacheLoaded
		return
	_HS_ExtensionsCache := _HotstringExtensionPacks
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

; True when the personal hotstrings' gate is open (it follows the Hotstrings
; master) and every section HS_TogglePersonalAllSections switches is on: the tick
; of the personal « all sections » checkbox.
_HS_PersonalSectionsAllOn(TomlData) {
	Paths := []
	for _, SecName in TomlData["sections_order"] {
		if (SecName != "-")
			Paths.Push("hotstrings.personal." . StrLower(SecName))
	}
	return _HS_ScopeAllOn(["Personal"], Paths)
}

; The editor has no input-master prerequisite. Its live pause owner admits both
; the rendered leaf and a callback retained before suspension.
_HS_PersonalEditorReady(PausedFn) {
	try {
		Paused := PausedFn.Call()
		return (Paused is Integer) && Paused == 0
	} catch
		return false
}

_HS_PersonalEditorRow(OpenFn, PausedFn := 0) {
	if !IsObject(PausedFn)
		PausedFn := (*) => A_IsSuspended
	return MenuRenderer_CommandRow("personal_hotstring_commands", "personal_hotstring_open_editor",
		Map("personal_hotstring_open_editor", OpenFn),
		Map("personal_hotstring_editor_ready", _HS_PersonalEditorReady.Bind(PausedFn)))
}

; Dynamic handler: personal hotstrings (personal_hotstrings.toml + pre-scanned ext tree).
_HS_PersonalRows(Options := unset) {
	if !IsSet(Options)
		Options := Map()
	global ScriptInformation, Features, _PersonalExtTree
	Rows := []
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
		; The two Menu objects are created here and kept, because two callbacks
		; below REPAINT them: choosing a default section renames the parent row and
		; moves the tick without rebuilding anything, and so does the close-on-add
		; switch. A full RebuildTrayMenu costs about a second, which is not a price
		; a checkmark can pay.
		;
		; That is not a reason for the rows themselves to be hand-built, which is
		; what they were until 2026-08-07: MenuRenderer_AppendRows renders row DATA
		; into a menu the CALLER owns, so the driver can hold the reference it needs
		; and still let the renderer draw every row in it.
		PersonalMenu       := Menu()
		DefaultSectionMenu := Menu()
		PersonalRows := []
		PersonalRows.Push(_HS_PersonalEditorRow((*) => OpenPersonalEditor()))
		PersonalRows.Push(Map("label", t("menu.hotstrings.open_file"), "action", _MakeOpenFileFn(PersonalTomlPath)))
		PersonalRows.Push(Map("separator", true))

		CurDefaultSec := _EditorPrefGet("DefaultSection", "")
		DefaultRows := []
		DefaultRows.Push(Map(
			"label",   t("menu.hotstrings.default_none"),
			"action",  _MakeSetDefaultSectionFn("", PersonalMenu, TomlData, DefaultSectionMenu, DisambiguatedLabels),
			"checked", (CurDefaultSec == "") ? true : false))
		DefaultRows.Push(Map("separator", true))
		for _, SecName in TomlData["sections_order"] {
			if (SecName == "-")
				continue
			if !TomlData["sections"].Has(SecName)
				continue
			SecLabel := DisambiguatedLabels[SecName]
			DefaultRows.Push(Map(
				"label",   SecLabel,
				"action",  _MakeSetDefaultSectionFn(SecName, PersonalMenu, TomlData, DefaultSectionMenu, DisambiguatedLabels),
				"checked", (CurDefaultSec == SecName) ? true : false))
		}
		MenuRenderer_AppendRows(DefaultSectionMenu, "hotstrings_menu", "hotstring_personal_default", DefaultRows)

		CurDefaultLabel := (CurDefaultSec == "") ? t("menu.hotstrings.default_none")
			: (DisambiguatedLabels.Has(CurDefaultSec) ? DisambiguatedLabels[CurDefaultSec] : CurDefaultSec)
		global _PrevDefaultLabel := CurDefaultLabel
		PersonalRows.Push(Map(
			"label",   t("menu.hotstrings.default_category_prefix") . CurDefaultLabel,
			"submenu", DefaultSectionMenu))
		PersonalRows.Push(Map(
			"label",   t("menu.hotstrings.close_on_add"),
			"action",  _TogglePersonalCloseOnAddFromHandle.Bind(PersonalMenu.Handle),
			"checked", (_EditorPrefGet("close_on_add", "1") == "1") ? true : false))
		if (TomlData["sections_order"].Length > 0) {
			PersonalRows.Push(Map("separator", true))
			for _, SecName in TomlData["sections_order"] {
				if (SecName == "-") {
					PersonalRows.Push(Map("separator", true))
					continue
				}
				if !TomlData["sections"].Has(SecName)
					continue
				SecData  := TomlData["sections"][SecName]
				SecLabel := DisambiguatedLabels[SecName] . " (" . FmtCount(SecData["entries"].Length) . ")"
				; v2 path for a runtime-discovered personal section: the Features
				; node (and config.toml section) key the lowercased TOML section name.
				Row := MenuRowWithLabel("hotstrings.personal." . StrLower(SecName), SecLabel, "Hotstrings")
				if (Row != "") {
					PersonalRows.Push(Row)
				}
			}
		}
		_HS_CategoryMenu("Personal", "", PersonalRows,
			(_Targets, Enabled) => HotstringsPersonalScopeApply(Enabled, Options), PersonalMenu)
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
			if !ReadFeatureStateV2("hotstrings.personal." . PV2Id).Get("enabled", false)
				PersonalAllEnabled := false
		}
		PersonalTitle := GetCategoryTitle("Personal") . " (" . FmtCount(PersonalActiveCount) . ")"
		Rows.Push(Map(
			"label",   PersonalTitle,
			"checked", (PersonalAllEnabled and PersonalSectionCount > 0) ? true : false,
			"submenu", PersonalMenu))
	}

	RootNode := false
	TreeCopy := _PersonalExtTree.Clone()
	if TreeCopy.Has("") {
		RootNode := TreeCopy[""]
		TreeCopy.Delete("")
	}
	_HS_RenderTree(TreeCopy, "", Rows)
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
			Rows.Push(_HS_TomlFileRow(TF))
		}
	}
	return Rows
}

; One TOML file of the personal-extensions tree, as a row whose submenu holds
; independent admitted controls, or a read-only unavailable section inventory.
;
; Its own Menu, filled by the renderer from row data: a folder tree follows the
; USER's directories, so each level builds a menu and hands the level below it
; over as `submenu` rather than describing the whole tree as one nested array.
; Every level is still drawn by the renderer, which is the point — the driver
; decides the SHAPE of the tree, never how a row is drawn.
_HS_TomlFileRow(TF) {
	TFMenu := Menu()
	FileRows := [Map("label", t("menu.hotstrings.open_file"), "action", _MakeOpenFileFn(TF.path))]
	Owner := PersonalFileControls.ForPath(TF.path)
	if Owner is PersonalFileAdoptedOwner {
		FileRows.Push(Map("separator", true))
		for Row in _HS_PersonalFileControlRows(Owner, "")
			FileRows.Push(Row)
		for Section in Owner.sectionNames {
			FileRows.Push(Map("label", Section . " (" . FmtCount(Owner.counts[Section]) . ")",
				"items", _HS_PersonalFileControlRows(Owner, Section), "checked", Owner.Selected(Section)))
		}
	} else {
		Unavailable := _HS_PersonalUnavailableRow("file")
		if Unavailable is Map
			FileRows.Push(Unavailable)
		for _, ES in TF.sections
			FileRows.Push(Map("label", ES["description"] . " (" . FmtCount(ES["count"]) . ")"))
	}
	MenuRenderer_AppendRows(TFMenu, "hotstrings_menu", "hotstring_personal_ext", FileRows)
	return Map(
		"label", TF.stem . " (" . FmtCount(Owner is PersonalFileAdoptedOwner ? Owner.ActiveCount() : TF.count) . ")",
		"submenu", TFMenu)
}

; Shared declarations own fixed labels, check/command kinds, order and reasons.
; Native callbacks operate only on the captured adopted owner and its exact scope.
_HS_PersonalFileControlRows(Owner, Section, Options := unset) {
	OwnedOptions := IsSet(Options) ? Options : Map()
	Resolved := Owner.Resolve(Section)
	Commands := Map(
		"personal_file_enabled", (*) => Owner.Commit(Section, "enabled", !Owner.Selected(Section), OwnedOptions),
		"personal_file_delay", (*) => _HS_PromptPersonalFileField(Owner, Section, "delay"),
		"personal_file_priority", (*) => _HS_PromptPersonalFileField(Owner, Section, "priority"),
		"personal_file_color", (*) => _HS_PromptPersonalFileField(Owner, Section, "color"),
		"personal_file_tooltip", (*) => Owner.Commit(Section, "show_tooltip", !Owner.Resolve(Section).ShowTooltip, OwnedOptions))
	Getters := Map(
		"personal_file_owner_ready", (*) => PersonalFileControls.IsCurrent(Owner),
		"personal_file_enabled", (*) => Owner.Selected(Section),
		"personal_file_tooltip", (*) => Owner.Resolve(Section).ShowTooltip)
	Values := Map("personal_file_delay", Round(Resolved.Delay * 1000),
		"personal_file_priority", Resolved.Priority, "personal_file_color", Resolved.Color)
	Rows := [], Definition := _MR_GetMenuDef("personal_file_controls")
	if !(Definition is Array)
		return Rows
	for Item in Definition {
		Id := _MR_Get(Item, "id")
		Row := _MR_Get(Item, "type") == "check"
			? MenuRenderer_CheckRow("personal_file_controls", Id, Commands, Getters)
			: MenuRenderer_CommandRow("personal_file_controls", Id, Commands, Getters)
		if !(Row is Map)
			continue
		if Values.Has(Id)
			Row["label"] .= " : " . Values[Id]
		Rows.Push(Row)
	}
	return Rows
}

; Refused native source inventories retain a declared translated reason and no action.
_HS_PersonalUnavailableRow(Kind, Prefix := "") {
	Id := Kind == "directory" ? "personal_directory_unavailable" : "personal_file_unavailable"
	Getter := Kind == "directory" ? "personal_directory_ready" : "personal_file_owner_ready"
	Row := MenuRenderer_CommandRow(Id, Id,
		Map(Id, (*) => false), Map(Getter, (*) => false))
	if Row is Map && Prefix != ""
		Row["label"] := Prefix . " — " . Row["label"]
	return Row
}

; Validate native prompt values before the exclusive owner admits a publication.
_HS_PromptPersonalFileField(Owner, Section, Field) {
	Resolved := Owner.Resolve(Section)
	Current := Field == "delay" ? Round(Resolved.Delay * 1000)
		: (Field == "priority" ? Resolved.Priority : Resolved.Color)
	Prompt := Ui_InputBox(t("hs_config.label_" . Field), Owner.source["label"], "w340 h140", Current)
	if Prompt.Result != "OK"
		return
	Value := Trim(Prompt.Value)
	if Field == "delay" || Field == "priority" {
		if !RegExMatch(Value, "^\d+$")
			return false
		Value := Integer(Value)
		if Field == "delay"
			Value /= 1000
	} else if !RegExMatch(Value, "^#?[0-9A-Fa-f]{6}$")
		return false
	return Owner.Commit(Section, Field, Value)
}

; Sum all hotstring counts inside a node and its sub-nodes recursively.
_HS_NodeTotal(Node) {
	Total := 0
	for _, TF in Node["tomls"] {
		Owner := PersonalFileControls.ForPath(TF.path)
		Total += Owner is PersonalFileAdoptedOwner ? Owner.ActiveCount() : TF.count
	}
	for _, Sub in Node["subfolders"]
		Total += _HS_NodeTotal(Sub)
	return Total
}

; Render recursive ext tree (nested folder structure).
;
; ``Rows`` is how the TOP level is called since 2026-08-07: the personal block is
; a `list` provider, which is handed no menu, so its folders have to come back as
; row data. The nested levels still take a ParentMenu, because a folder's
; children genuinely hang off the folder's own Menu. Passing `M` here — the name
; a dynamic handler's menu parameter used to have — is what made the provider
; throw and took the entire tray menu down with it.
;
; Every level is row DATA rendered into that level's own Menu since 2026-08-07.
; The tree mirrors the user's folder layout, which has no depth limit, and the
; renderer caps a NESTED row array at MR_MAX_LIST_DEPTH to stop a self-referential
; provider from recursing until the stack gives out — but that cap counts nesting
; inside one array, and this walk starts a fresh render at each level. So the walk
; keeps its own recursion, which is what a filesystem needs, and the renderer
; still draws every row, which is what one menu needs.
_HS_RenderTree(Tree, ParentMenu, Rows := "") {
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
	; The folder rows of THIS level. They go back to the caller when it asked for
	; data (the top level, which is a list provider) and are rendered into the
	; parent's menu otherwise (every level below it).
	FolderRows := (Rows is Array) ? Rows : []
	for _, FolderName in FolderNames {
		Node := Tree[FolderName]
		if Node.Get("unavailable", false) {
			Unavailable := _HS_PersonalUnavailableRow("directory", FolderName)
			if Unavailable is Map
				FolderRows.Push(Unavailable)
			continue
		}
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
		; Subfolders first — they render themselves into FolderMenu — then the
		; files of this folder, appended after them.
		if (Node["subfolders"].Count > 0)
			_HS_RenderTree(Node["subfolders"], FolderMenu)
		FileRows := []
		if (Node["subfolders"].Count > 0 and FileNodeList.Length > 0)
			FileRows.Push(Map("separator", true))
		for _, TF in FileNodeList {
			FileRows.Push(_HS_TomlFileRow(TF))
		}
		MenuRenderer_AppendRows(FolderMenu, "hotstrings_menu", "hotstring_personal_ext", FileRows)
		FolderTotal := _HS_NodeTotal(Node)
		FolderLabel := FolderName . (FolderTotal > 0 ? " (" . FmtCount(FolderTotal) . ")" : "")
		FolderRows.Push(Map("label", FolderLabel, "submenu", FolderMenu))
	}
	if !(Rows is Array) {
		MenuRenderer_AppendRows(ParentMenu, "hotstrings_menu", "hotstring_personal_ext", FolderRows)
	}
}

; List provider: explicit group and section choices for the boot-owned catalogue.
; Checks reflect desired values; counts reflect effective registration.
_HS_ExtensionRows(Options := unset) {
	global _HS_ExtensionsCache, Features
	if !IsSet(Options)
		Options := Map()
	Rows := []
	_HS_PreScanExtensions()
	if (_HS_ExtensionsCache.Length == 0) {
		return [Map("label", t("menu.extensions.empty"), "disabled", true)]
	}
	MasterOn := IsCategoryGated("Hotstrings")
	for _, Ext in _HS_ExtensionsCache {
		ExtRows := []
		; The categories the extension binds come first: « Hotstrings Ergopti »
		; opens on SFB reduction and rolls, then any pack of its own.
		Bound := _HS_BoundCategoryRows(Ext.id)
		for _, Row in Bound.rows
			ExtRows.Push(Row)
		ExtTotalForExt := HotstringExtensions_Count(Features, [Ext], MasterOn) + Bound.total
		if (Ext.toml_files.Length == 0) {
			if (Bound.rows.Length == 0)
				ExtRows.Push(Map("label", t("menu.extensions.empty"), "disabled", true))
		} else {
			for _, TF in Ext.toml_files {
				GroupPath := "hotstrings.groups." . TF.category
				TFRows := []
				if (TF.sections.Length == 0) {
					TFRows.Push(Map("label", t("menu.extensions.empty"), "disabled", true))
				} else {
					for _, Sec in TF.sections {
						SectionPath := "hotstrings.modules." . TF.category . "." . Sec["name"]
						TFRows.Push(Map(
							"label",    Sec["description"] . " (" . FmtCount(Sec["count"]) . ")",
							"checked", ReadFeatureStateV2(SectionPath)["enabled"],
							"action", _HS_ExtensionToggle.Bind(SectionPath, Options)))
					}
				}
				ExtRows.Push(Map(
					"label", TF.stem . " (" . FmtCount(HotstringExtensions_Count(Features,
						[{ toml_files: [TF] }], MasterOn)) . ")",
					"checked", ReadFeatureStateV2(GroupPath)["enabled"],
					"submenu", _HS_CategoryMenu(TF.category, TF.path, TFRows,
						(Targets, Enabled) => HotstringExtensions_SetCategoryEnabled(Targets[1], Enabled, Options))))
			}
		}
		if Ext.toml_files.Length || (Ext.HasOwnProp("bound_files") && Ext.bound_files.Length) {
			for Command in _HS_ExtensionScopeCommandRows(Ext.id, Options)
				ExtRows.Push(Command)
		}
		Rows.Push(Map(
			"label", StrReplace(t("menu.extensions.hotstrings_of"), "%s", Ext.name)
				. " (" . FmtCount(ExtTotalForExt) . ")",
			"items", ExtRows))
	}
	return Rows
}

; Reuse the shared explicit command declarations; the atomic owner resolves
; current whole groups and bound leaves again when a retained row is clicked.
_HS_ExtensionScopeCommandRows(ExtensionId, Options) {
	Commands := Map(
		"hotstring_category_enable_all", (*) => HotstringsExtensionScopeApply(ExtensionId, true, Options),
		"hotstring_category_disable_all", (*) => HotstringsExtensionScopeApply(ExtensionId, false, Options))
	Rows := []
	for Id in ["hotstring_category_enable_all", "hotstring_category_disable_all"] {
		Row := MenuRenderer_CommandRow("hotstring_category_menu", Id, Commands)
		if Row is Map {
			Row["disabled"] := A_IsSuspended
			Rows.Push(Row)
		}
	}
	return Rows
}

; Read intent on the click, so an older menu never inverts a masked runtime flag.
_HS_ProgrammableHotstringRows() {
	Commands := Map("open_user_hotstring_source", UserHotstringsOpenSource,
		"reload_user_hotstring_source", UserHotstringsReload,
		"create_user_hotstring_example", UserHotstringsCreateExample)
	Rows := []
	for Declaration in _MR_GetMenuDef("programmable_hotstrings") {
		if !(Declaration is Map)
			continue
		if Declaration.Get("type", "") == "feature" {
			Label := _ApplyMenuLabelDynamicSubstitutions(t(Declaration["i18n"]), Declaration["path"])
			Row := MenuRowWithLabel(Declaration["path"], Label, "DynamicHotstrings")
		} else if Declaration.Get("type", "") == "command" {
			Row := MenuRenderer_CommandRow("programmable_hotstrings", Declaration["id"], Commands)
		} else {
			continue
		}
		if Row is Map
			Rows.Push(Row)
	}
	return Rows
}

_HS_ExtensionToggle(Path, Options, *) {
	return HotstringExtensions_SetEnabled(Path, !ReadFeatureStateV2(Path)["enabled"], Options)
}

; New records join the conditional config.toml/reload owner; legacy string
; controls remain separate and cannot silently substitute for refused records.
_HS_DelimAddRecordCommit(Char, Consume, Options := unset) {
	if !HotstringsTerminatorRecordCharacter(Char) || !(Consume is Integer)
			|| (Consume != 0 && Consume != 1) || A_IsSuspended
		return false
	Record := Map("key", "custom_" . Format("{:X}", Ord(Char)), "char", Char,
		"label", Char . " : " . t("menu.hotstrings.custom_label"), "consume", TOML_Bool(Consume))
	return HotstringsTerminatorRecordsEdit(Map("mode", "add", "record", Record), Options?)
}

_HS_DelimRemoveRecord(Key, Options := unset) {
	if A_IsSuspended
		return false
	if Ui_MsgBox(t("dialog.hotstrings.delete_delimiter_body"),
			t("dialog.hotstrings.delete_delimiter_title"), "YesNo") != "Yes"
		return false
	return HotstringsTerminatorRecordsEdit(Map("mode", "remove", "key", Key), Options?)
}

_HS_DelimRecordState(Key, Enabled, Options := unset) {
	if A_IsSuspended
		return false
	return HotstringsTerminatorRecordsEdit(
		Map("mode", "state", "key", Key, "enabled", Enabled), Options?)
}
