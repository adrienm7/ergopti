; tests/unit/test_llm_menu_backend_model_labels.ahk

; ==============================================================================
; MODULE: LLM Menu Backend/Model Label Tests
; DESCRIPTION:
; The IA submenu parent rows must show display names, not storage ids: the
; backend row reads what its submenu shows for the selected backend, cut
; before the em dash (« API 🌐 », never « Backend : api »), and the model row
; follows the active backend — with backend api it shows the selected API
; entry's automatic name, <provider>/<model> with the model requests use,
; never the stale Ollama tag from before the switch. The Ollama slot
; itself is preserved untouched so switching back restores it.
; ==============================================================================

#Requires AutoHotkey v2.0

; backend-row-selected-option. The Backend row read « Backend : API »; the
; maintainer asked on 2026-09-30 for the selected option as the submenu lists
; it, cut before its em dash, emoji included. The expected text is read from
; the submenu's own checked row, then pinned to the brand it must start with.
_LBMD_BackendRowLabel() {
	global _LLM_Menu
	Assert(_DriverFuncBody("_LLM_Menu_BackendRowLabel") != "",
		"_LLM_Menu_BackendRowLabel must exist in menu_models.ahk")
	SavedMenu := _LLM_Menu
	try {
		for Backend, Expected in Map("api", "API 🌐", "ollama", "Ollama 🦙") {
			_LLM_Menu := Map("backend", Backend, "ollama_port", 11434)
			Checked := ""
			for Row in _LLM_Menu_BackendRows() {
				if Row.Get("checked", false)
					Checked := Row["label"]
			}
			AssertContains(Checked, " — ", Backend . ": the option carries its description after an em dash")
			AssertEqual(Expected, _LLM_Menu_BackendRowLabel(),
				Backend . ": the row names the selected option, emoji included")
			AssertEqual(Expected, Trim(SubStr(Checked, 1, InStr(Checked, "—") - 1)),
				Backend . ": the row is the checked option cut before its em dash")
		}
		_LLM_Menu := Map("backend", "mlx", "ollama_port", 11434)
		AssertEqual(t("menu.llm.backend_unknown"), _LLM_Menu_BackendRowLabel(),
			"a backend the submenu does not offer is named unknown, never blank")
	} finally _LLM_Menu := SavedMenu
	AssertEqual("MLX 🚀", _LLM_Menu_OptionHead("MLX 🚀 — Recommandé — natif"),
		"the head stops at the first em dash")
	AssertEqual("Sans tiret", _LLM_Menu_OptionHead(" Sans tiret "),
		"a label without an em dash is shown whole")
}
Test("backend-row-selected-option: the Backend row names the selected option",
	_LBMD_BackendRowLabel)

; A definitions-only include must own its catalogue too. Reordering it must
; change the rendered options without changing the stored backend or port.
_LBMD_BackendCatalogueRows() {
	global _LLM_Menu, LLM_MENU_BACKEND_OPTIONS
	SavedMenu := _LLM_Menu
	SavedOptions := LLM_MENU_BACKEND_OPTIONS
	try {
		LLM_MENU_BACKEND_OPTIONS := ["api", "ollama"]
		for Backend in LLM_MENU_BACKEND_OPTIONS {
			_LLM_Menu := Map("backend", Backend, "ollama_port", 11434)
			Rows := _LLM_Menu_BackendRows()
			Checked := 0
			for Index, Id in LLM_MENU_BACKEND_OPTIONS {
				AssertEqual(_LLM_Menu_BackendOptionLabel(Id), Rows[Index]["label"],
					"backend rows preserve the declared catalogue order")
				AssertEqual(Id == Backend, Rows[Index]["checked"],
					"only the selected backend is checked")
				Assert(HasMethod(Rows[Index]["action"], "Call"),
					"each backend remains actionable")
				Checked += Rows[Index]["checked"] ? 1 : 0
			}
			AssertEqual(1, Checked, "exactly one supported backend is checked")
			AssertEqual(Backend, _LLM_Menu["backend"], "building does not change the selection")
			AssertEqual(11434, _LLM_Menu["ollama_port"], "building does not change the server port")
			Assert(LLM_Menu_BuildBackendMenu() is Menu,
				"the native renderer builds from the definitions-only catalogue")
		}
	} finally {
		_LLM_Menu := SavedMenu
		LLM_MENU_BACKEND_OPTIONS := SavedOptions
	}
}
Test("llm menu: definitions-only backend catalogue renders in declared order",
	_LBMD_BackendCatalogueRows)

_LBMD_ModelDisplayText() {
	global _LLM_Menu, LLM_API_PROVIDERS
	Assert(_DriverFuncBody("_LLM_Menu_ModelDisplayText") != "",
		"_LLM_Menu_ModelDisplayText must exist in menu_models.ahk")
	Assert(_DriverFuncBody("_LLM_Menu_ApiEntryDisplayName") != "",
		"_LLM_Menu_ApiEntryDisplayName must exist in menu_models.ahk")
	SavedMenu := _LLM_Menu
	try {
		_LLM_Menu := Map("backend", "api", "model", "stale-ollama-tag",
			"api_entry_id", "e1",
			"api_entries", [Map("Id", "e1", "Name", "Cerebras",
				"Provider", "cerebras", "BaseUrl", "https://b.invalid/v1",
				"Token", "sekret", "Model", "qwen-3.8-27b")])
		AssertEqual("cerebras/qwen-3.8-27b", _LLM_Menu_ModelDisplayText(),
			"with backend api the row shows the entry's automatic name, not its stored one")
		AssertEqual("cerebras/qwen-3.8-27b",
			_LLM_Menu_ApiEntryDisplayName(_LLM_Menu["api_entries"][1]))
		_LLM_Menu["api_entries"][1]["Model"] := ""
		AssertEqual("cerebras/" . LLM_API_PROVIDERS["cerebras"]["DefaultModel"],
			_LLM_Menu_ModelDisplayText(),
			"an entry without a model is named after the provider default")
		_LLM_Menu["api_entry_id"] := "ghost"
		AssertEqual("", _LLM_Menu_ModelDisplayText(),
			"an unknown entry never resurrects the stale ollama tag")
		_LLM_Menu["backend"] := "ollama"
		_LLM_Menu["api_entry_id"] := "e1"
		AssertEqual("stale-ollama-tag", _LLM_Menu_ModelDisplayText(),
			"with backend ollama the preserved slot shows untouched")
	} finally _LLM_Menu := SavedMenu
}
Test("llm menu: model row follows the active backend (llm-menu-model-label)",
	_LBMD_ModelDisplayText)

; The EmitRow cases must route both labels through the helpers instead of
; the raw storage slots. Scanned comment-stripped so prose can never
; satisfy the assertions.
_LBMD_RowsUseDisplayHelpers() {
	Main := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_EmitRow"))
	Assert(Main != "", "_LLM_Menu_EmitRow must remain source-visible")
	Assert(InStr(Main, "_LLM_Menu_BackendRowLabel(") > 0,
		"the backend row must name the selected option")
	Assert(InStr(Main, "_LLM_Menu_ModelDisplayText(") > 0,
		"the model row must use the display-text helper")
	Assert(InStr(Main, 'StrReplace(t("menu.llm.model_backend"), "%s", _LLM_Menu["backend"])') == 0,
		"the backend row must not show the raw storage id")
	Assert(InStr(Main, 'StrReplace(t("menu.llm.model_label"), "%s", _LLM_Menu["model"])') == 0,
		"the model row must not show the raw ollama slot")
}
Test("llm menu: parent rows route through display helpers (llm-menu-label-wiring)",
	_LBMD_RowsUseDisplayHelpers)


; A callable native browser port returns its own presentation receipt unchanged.
_LBMD_ModelBrowserOpen(Seen) {
	Seen["calls"] += 1
	return Seen["result"]
}

_LBMD_ModelBrowserSharedCommand() {
	Body := _DriverFuncBody("_LLM_Menu_ModelBrowserRow")
	Assert(Body != "", "the actual browser provider must exist")
	AssertContains(Body, 'MenuRenderer_CommandRow("llm_model_commands", "llm_browse_models"',
		"the fixed browser row must use its shared declaration")
	Seen := Map("calls", 0, "result", "owned-browser-receipt")
	Row := _LLM_Menu_ModelBrowserRow(_LBMD_ModelBrowserOpen.Bind(Seen))
	Assert(Row is Map, "the browser provider must return row data")
	AssertEqual(t("menu.llm.browse_models_entry"), Row["label"],
		"the browser caption is the canonical translated command")
	Assert(!Row.Has("checked"), "browser presentation does not toggle a setting")
	AssertEqual("owned-browser-receipt", Row["action"].Call(),
		"the existing native browser owns its presentation receipt")
	AssertEqual(1, Seen["calls"], "the command reaches one native browser owner")
	Seen["result"] := false
	AssertEqual(false, Row["action"].Call(), "native browser refusal must be retained")
	AssertEqual(2, Seen["calls"], "refusal cannot retry another browser owner")
}
Test("models browser: fixed command uses shared metadata and native presentation receipts",
	_LBMD_ModelBrowserSharedCommand)

_LBMD_ModelBrowserUnavailablePort() {
	Row := _LLM_Menu_ModelBrowserRow(Map("future", true))
	Assert(!IsObject(Row) || Row.Get("disabled", false),
		"an object without a callable browser cannot become an enabled command")
	if Row is Map && Row.Has("action")
		AssertEqual(false, Row["action"].Call(),
			"the shared command must refuse a retained unavailable browser port")
}
Test("models browser: unavailable native presentation ports fail closed",
	_LBMD_ModelBrowserUnavailablePort)

; The definitions-only runner has no native WebView browser implementation.
_LBMD_ModelBrowserAbsentDefaultPort() {
	Assert(!IsSet(LLM_ModelBrowser_Show),
		"the real definitions-only graph must not inject a native browser stand-in")
	Row := _LLM_Menu_ModelBrowserRow()
	Assert(Row is Map, "an unavailable native browser retains the declared row")
	AssertEqual(true, Row.Get("disabled", false),
		"an absent default browser cannot produce an enabled command")
	AssertEqual(false, Row["action"].Call(),
		"a retained command must refuse the missing actual native browser")
	Seen := Map("calls", 0, "result", "supplied-native-browser-receipt")
	Supplied := _LLM_Menu_ModelBrowserRow(_LBMD_ModelBrowserOpen.Bind(Seen))
	AssertEqual(false, Supplied.Get("disabled", false),
		"an explicitly supplied callable retains its availability")
	AssertEqual(0, Seen["calls"], "building a callable row must not open the browser")
	AssertEqual("supplied-native-browser-receipt", Supplied["action"].Call(),
		"the supplied native port retains its exact presentation receipt")
	AssertEqual(1, Seen["calls"], "only the supplied native browser is invoked")
}
Test("models browser: an absent default native port refuses without hiding supplied capability",
	_LBMD_ModelBrowserAbsentDefaultPort)

; The actual model-picker tail owns Add and browser; only its inert boundary is shared.
_LBMD_ModelPickerBoundary(Mode) {
	Owner := _MR_FindItemById("llm_menu", "llm_model")
	Assert(Owner is Map && Owner.Has("status_rows"), "actual native model provider owns its status")
	Statuses := Owner["status_rows"]
	Assert(Statuses is Map && Statuses.Has("model_picker_tail"))
	Saved := Statuses["model_picker_tail"]
	SavedId := Owner["id"]
	AssertEqual(1, Saved.Length, "one independent boundary declaration")
	AssertEqual("---", Saved[1]["type"], "a separator, never a clicked row")
	AssertEqual(1, Saved[1].Count, "no hidden native action is declared")
	Effects := Map("calls", 0)
	Native := 0
	try {
		if Mode == "missing"
			Statuses.Delete("model_picker_tail")
		else if Mode == "wrong_owner"
			Owner["id"] := "foreign_model"
		else if Mode == "label"
			Statuses["model_picker_tail"] := [Map("type", "label", "i18n", "common.restore_recommended")]
		else if Mode == "clicked"
			Statuses["model_picker_tail"] := [Map("type", "command", "id", "unowned", "action", (*) => Effects["calls"] += 1)]
		else if Mode == "extra_callback"
			Statuses["model_picker_tail"] := [Map("type", "---", "action", (*) => Effects["calls"] += 1)]
		Rows := _LLM_Menu_ModelTailRows()
		Assert(Rows is Array, "the actual native tail provider survives refused inert presentation")
		HasBoundary := Mode == "original" || Mode == "label"
		AssertEqual(HasBoundary ? 3 : 2, Rows.Length)
		AddAt := HasBoundary ? 2 : 1
		AssertEqual(t("menu.llm.add_model_entry"), Rows[AddAt]["label"], "original Add remains before browser on Windows")
		Assert(Rows[AddAt]["action"].HasMethod("Call"), "actual native Add callback remains callable")
		AssertEqual(t("menu.llm.browse_models_entry"), Rows[AddAt + 1]["label"], "real shared browser is retained")
		Assert(Rows[AddAt + 1]["action"].HasMethod("Call"))
		if Mode == "original"
			AssertEqual(true, Rows[1]["separator"])
		else if Mode == "label" {
			AssertEqual(t("common.restore_recommended"), Rows[1]["label"])
			AssertEqual(true, Rows[1]["disabled"])
			Assert(!Rows[1].Has("action"), "inert presentation cannot acquire a command")
		}
		AssertEqual(0, Effects["calls"], "refused metadata never executes its injected callback")
		Native := Menu()
		MenuRenderer_AppendRows(Native, "llm_menu", "llm_model", Rows)
		AssertEqual(Rows.Length, DllCall("GetMenuItemCount", "ptr", Native.Handle, "int"), "actual Win32 tail contains every surviving sibling")
		State := DllCall("GetMenuState", "ptr", Native.Handle, "uint", 0, "uint", 0x400, "uint")
		Assert(State != 0xFFFFFFFF, "native position must genuinely exist")
		if Mode == "original"
			Assert((State & 0x800) != 0, "actual Win32 separator is shared presentation")
		else if Mode == "label"
			Assert((State & 3) != 0 && (State & 0x800) == 0, "actual inert replacement is disabled text")
		else
			Assert((State & 0x800) == 0, "a refused boundary cannot be fabricated by a native wrapper")
	} finally {
		if Native is Menu
			_CTC_ReleaseMenu(Native)
		Statuses["model_picker_tail"] := Saved
		Owner["id"] := SavedId
	}
}
for Mode in ["original", "label", "missing", "wrong_owner", "clicked", "extra_callback"]
	Test("models picker: actual shared tail boundary and real native siblings " . Mode,
		_LBMD_ModelPickerBoundary.Bind(Mode))

_LBMD_ModelPickerBoundaryConsumer() {
	Body := _StripFullLineComments(_DriverFuncBody("LLM_Menu_BuildModelMenu"))
	AssertContains(Body, 'MenuRenderer_AppendRows(m, "llm_menu", "llm_model", _LLM_Menu_ModelTailRows())',
		"the actual native model-menu consumer must render the complete tail provider")
	Tail := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_ModelTailRows"))
	AssertContains(Tail, 'MenuRenderer_StatusRows("llm_menu", "llm_model", "model_picker_tail")')
	AssertContains(Tail, '"llm_add_model_entry", (*) => LLM_Menu_PromptAddModel()', "original Add dialog callback body remains native")
	Assert(_LMNM_AddRoute(Tail), "the named Add binding must reach and join the actual typed tail consumer")
	AssertContains(Tail, '_LLM_Menu_ModelBrowserRow()', "original browser admission owner remains native")
	Assert(InStr(Tail, 'Map("separator", true)') == 0, "no native fallback separator may replace a refused declaration")
}
Test("models picker: actual model-menu consumer retains native owners and shared boundary",
	_LBMD_ModelPickerBoundaryConsumer)


/** Exercises the actual backend provider, preserving native option and port state. */
_LBMD_BackendBoundary() {
	global _LLM_Menu, LLM_MENU_BACKEND_OPTIONS, _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\backend_choice_boundary.json", "UTF-8"))
	SavedMenu := _LLM_Menu
	SavedOptions := LLM_MENU_BACKEND_OPTIONS
	Frame := _MR_GetMenuDef(Corpus["section"])
	Original := Frame[1]
	try {
		LLM_MENU_BACKEND_OPTIONS := ["api", "ollama"]
		_LLM_Menu := Map("backend", "api", "ollama_port", 11434)
		Rows := _LLM_Menu_BackendRows()
		AssertTrue(Rows[3]["separator"], "the native provider allocates its declared boundary after both choices")
		Frame[1] := Map("type", "label", "id", "backend_boundary_marker", "i18n", Corpus["marker_key"],
			"platforms", ["ahk", "linux"], "unavailable", "hide")
		Rows := _LLM_Menu_BackendRows()
		AssertEqual(t(Corpus["marker_key"]), Rows[3]["label"], "the actual shared declaration owns the boundary position")
		AssertTrue(Rows[3]["disabled"])
		AssertFalse(Rows[3].Has("action"))
		AssertEqual(StrReplace(t(Corpus["windows_next_key"]), "%s", 11434), Rows[4]["label"],
			"the unchanged real port control follows the boundary in the current native locale")
		AssertTrue(HasMethod(Rows[4]["action"], "Call"))
		AssertTrue(Rows[1]["checked"])
		AssertFalse(Rows[2]["checked"])
		AssertTrue(HasMethod(Rows[1]["action"], "Call"))
		AssertTrue(HasMethod(Rows[2]["action"], "Call"))
		AssertEqual("api", _LLM_Menu["backend"])
		AssertEqual(11434, _LLM_Menu["ollama_port"])
		Frame[1] := Map("type", "command", "id", "unowned_backend_boundary", "i18n", Corpus["marker_key"],
			"platforms", ["ahk", "linux"], "unavailable", "hide")
		AssertEqual(0, _LLM_Menu_BackendRows().Length, "an unowned boundary refuses before native port controls")
		AssertEqual("api", _LLM_Menu["backend"])
		AssertEqual(11434, _LLM_Menu["ollama_port"])
	} finally {
		Frame[1] := Original
		_LLM_Menu := SavedMenu
		LLM_MENU_BACKEND_OPTIONS := SavedOptions
	}
}
Test("backend choices: actual shared boundary and native control owners (backend-choice-boundary)",
	_LBMD_BackendBoundary)


/** Reads the genuine catalogue record used by the actual per-model allocator. */
_LBMD_ReadoutCatalogueModel(Name) {
	global _SharedDir
	Providers := JsonParse(FileRead(_SharedDir . "\modules\llm\models.json", "UTF-8"))
	for Provider in Providers {
		for Family in Provider["families"] {
			for Model in Family["models"] {
				if Model.Get("name", "") == Name
					return Model
			}
		}
	}
	throw Error("Actual curated model missing: " . Name)
}

/** Proves genuine native frames consume shared metadata without acquiring actions. */
_LBMD_PerModelReadoutFrame(Key) {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\model_readout_frames.json", "UTF-8"))
	Expected := Corpus[Key]
	Model := _LBMD_ReadoutCatalogueModel(Corpus["native_model"])
	Name := Model["name"]
	Url := Model["urls"]["ollama"]
	Frame := _MR_GetMenuDef(Expected["section"])
	Original := Frame[2]
	Native := 0
	try {
		Rows := _LLM_Menu_PerModelRows(Name, Model, Url, Name, false)
		Position := 0
		for Index, Row in Rows {
			if Row.Get("label", "") == t(Expected["key"])
				Position := Index
		}
		Assert(Position > 1, "the real model allocator must reach the current native heading")
		AssertTrue(Rows[Position - 1]["separator"])
		AssertTrue(Rows[Position]["disabled"], "shared bare Windows headings are inert")
		AssertFalse(Rows[Position].Has("action"))
		AssertEqual(t(Corpus["selection_key"]), Rows[1]["label"])
		AssertTrue(Rows[1]["checked"])
		AssertTrue(HasMethod(Rows[1]["action"], "Call"))
		AssertTrue(HasMethod(Rows[2]["action"], "Call"), "the existing Download closure remains native")
		Native := Menu()
		MenuRenderer_AppendRows(Native, "llm_menu", "llm_model", Rows)
		AssertEqual(Rows.Length, DllCall("GetMenuItemCount", "ptr", Native.Handle, "int"))
		State := DllCall("GetMenuState", "ptr", Native.Handle, "uint", Position - 1, "uint", 0x400, "uint")
		Assert(State != 0xFFFFFFFF && (State & 3) != 0 && (State & 0x800) == 0,
			"the actual Win32 heading is disabled text, never a separator or live command")
		Frame[2] := Map("type", "label", "id", Original["id"], "i18n", Corpus["marker_key"],
			"platforms", ["ahk"], "unavailable", "hide")
		Rows := _LLM_Menu_PerModelRows(Name, Model, Url, Name, false)
		AssertEqual(t(Corpus["marker_key"]), Rows[Position]["label"], "the genuine native allocator consumes its current declaration")
		AssertTrue(Rows[Position]["disabled"])
		AssertFalse(Rows[Position].Has("action"))
		Frame[2] := Map("type", "command", "id", "unowned_readout", "i18n", Corpus["marker_key"],
			"platforms", ["ahk"], "unavailable", "hide")
		AssertEqual(0, _LLM_Menu_PerModelRows(Name, Model, Url, Name, false).Length,
			"an unowned shared command refuses before publishing any native row")
		Frame[2] := Original
		if Key == "caps" {
			Capabilities := Model["capabilities"]
			try {
				Model.Delete("capabilities")
				Rows := _LLM_Menu_PerModelRows(Name, Model, Url, Name, false)
				for Row in Rows
					AssertFalse(Row.Get("label", "") == t(Expected["key"]), "the existing capability absence predicate is retained")
			} finally Model["capabilities"] := Capabilities
		}
	} finally {
		Frame[2] := Original
		if Native is Menu
			_CTC_ReleaseMenu(Native)
	}
}
for Key in ["specs", "caps"]
	Test("per-model readout: authentic native sheet and shared frame " . Key,
		_LBMD_PerModelReadoutFrame.Bind(Key))


/** Exercises the actual catalogue allocator and current shared separator owners. */
_LBMD_CatalogueBoundary(Key) {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\model_catalogue_boundaries.json", "UTF-8"))
	Catalogue := JsonParse(FileRead(_SharedDir . "\modules\llm\models.json", "UTF-8"))
	Model := _LBMD_ReadoutCatalogueModel(Corpus["first_family_model"])
	Frame := _MR_GetMenuDef(Corpus["boundaries"][Key]["section"])
	Original := Frame[1]
	Root := _MM_GetManifestRoot()
	Native := 0
	OwnedRows() {
		if Key == "origin"
			return _LLM_Menu_PerModelRows(Model["name"], Model, Model["urls"]["ollama"], Model["name"], false)
		for Provider in _LLM_Menu_CatalogueRows(Catalogue, Model["name"], false) {
			if Provider["label"] == Corpus["provider_caption"]
				return Provider["items"]
		}
		return []
	}
	try {
		Rows := OwnedRows()
		Position := Key == "origin" ? Corpus["uninstalled_origin_position"]["ahk"] : 2
		Assert(Rows.Length > Position)
		AssertTrue(Rows[Position]["separator"])
		if Key == "origin" {
			AssertEqual(t("menu.llm.select_model"), Rows[1]["label"])
			AssertTrue(HasMethod(Rows[1]["action"], "Call"))
			AssertTrue(HasMethod(Rows[2]["action"], "Call"))
			AssertTrue(HasMethod(Rows[5]["action"], "Call"), "the existing source callback remains native")
		} else {
			Assert(InStr(Rows[1]["label"], Corpus["first_family_model"]))
			Assert(InStr(Rows[3]["label"], Corpus["second_family_model"]))
			AssertTrue(HasMethod(Rows[1]["items"][1]["action"], "Call"))
			AssertTrue(HasMethod(Rows[3]["items"][1]["action"], "Call"))
		}
		Native := Menu()
		MenuRenderer_AppendRows(Native, "llm_menu", "llm_model", Rows)
		AssertEqual(Rows.Length, DllCall("GetMenuItemCount", "ptr", Native.Handle, "int"))
		Flags := DllCall("GetMenuState", "ptr", Native.Handle, "uint", Position - 1, "uint", 0x400, "uint")
		Assert(Flags != 0xFFFFFFFF && (Flags & 0x800) != 0, "the native presentation boundary stays a separator")
		Frame[1] := Map("type", "label", "id", "catalogue_boundary_marker", "i18n", Corpus["published_marker_key"],
			"platforms", Original["platforms"], "unavailable", "hide")
		Rows := OwnedRows()
		AssertEqual(t(Corpus["published_marker_key"]), Rows[Position]["label"],
			"the real native allocator consumes the live shared boundary")
		AssertTrue(Rows[Position]["disabled"])
		AssertFalse(Rows[Position].Has("action"))
		if Key == "family" {
			Assert(InStr(Rows[1]["label"], Corpus["first_family_model"]))
			Assert(InStr(Rows[3]["label"], Corpus["second_family_model"]))
		}
		Root.Delete(Corpus["boundaries"][Key]["section"])
		AssertEqual(0, OwnedRows().Length, "a withdrawn boundary cannot publish a native fallback")
		Root[Corpus["boundaries"][Key]["section"]] := [Map("type", "command", "id", "unowned_catalogue_boundary", "i18n", Corpus["published_marker_key"])]
		AssertEqual(0, OwnedRows().Length, "an unbound command cannot become a separator")
		Root[Corpus["boundaries"][Key]["section"]] := Frame
		Frame[1] := Original
		AssertTrue(OwnedRows()[Position]["separator"], "repair retains the same actual allocator")
		AssertEqual(0, _LLM_Menu_CatalogueRows([], "", false).Length, "a genuinely absent catalogue creates no family boundary")
	} finally {
		Root[Corpus["boundaries"][Key]["section"]] := Frame
		Frame[1] := Original
		if Native is Menu
			_CTC_ReleaseMenu(Native)
	}
}
for Key in ["family", "origin"]
	Test("model catalogue boundaries: actual native owner " . Key, _LBMD_CatalogueBoundary.Bind(Key))


/** Captures each genuine translation owner without cloning its cache identity. */
_LBMD_HardwareLocaleState() {
	global _I18nLocale, _I18nCache, _I18nCacheLoaded, _I18nActiveCacheIdentity, _I18nMissWarned
	global _I18nCacheEn, _I18nCacheEnLoaded, _I18nCacheFr, _I18nCacheFrLoaded
	global _I18nFallbacksWarmed, _I18nFlagExistsCache
	return [_I18nLocale, _I18nCache, _I18nCacheLoaded, _I18nActiveCacheIdentity, _I18nMissWarned,
		_I18nCacheEn, _I18nCacheEnLoaded, _I18nCacheFr, _I18nCacheFrLoaded,
		_I18nFallbacksWarmed, _I18nFlagExistsCache]
}

/** Restores the exact translation objects and flags retained before the fixture. */
_LBMD_RestoreHardwareLocale(State) {
	global _I18nLocale, _I18nCache, _I18nCacheLoaded, _I18nActiveCacheIdentity, _I18nMissWarned
	global _I18nCacheEn, _I18nCacheEnLoaded, _I18nCacheFr, _I18nCacheFrLoaded
	global _I18nFallbacksWarmed, _I18nFlagExistsCache
	_I18nLocale := State[1]
	_I18nCache := State[2], _I18nCacheLoaded := State[3], _I18nActiveCacheIdentity := State[4]
	_I18nMissWarned := State[5]
	_I18nCacheEn := State[6], _I18nCacheEnLoaded := State[7]
	_I18nCacheFr := State[8], _I18nCacheFrLoaded := State[9]
	_I18nFallbacksWarmed := State[10], _I18nFlagExistsCache := State[11]
}

/** Loads the real locale while detached caches protect the preceding test cohort. */
_LBMD_WithHardwareLocale(Code, Body) {
	global _I18nCache, _I18nCacheLoaded, _I18nActiveCacheIdentity, _I18nMissWarned
	global _I18nCacheEn, _I18nCacheEnLoaded, _I18nCacheFr, _I18nCacheFrLoaded
	global _I18nFallbacksWarmed, _I18nFlagExistsCache
	Saved := _LBMD_HardwareLocaleState()
	try {
		_I18nCache := Map(), _I18nCacheLoaded := false, _I18nActiveCacheIdentity := false
		_I18nMissWarned := Map()
		_I18nCacheEn := Map(), _I18nCacheEnLoaded := false
		_I18nCacheFr := Map(), _I18nCacheFrLoaded := false
		_I18nFallbacksWarmed := false, _I18nFlagExistsCache := Map()
		I18nInit(Map("script", Map("locale", Code)))
		I18nPreload()
		AssertEqual(Code, I18nGetLocale(), "the real locale owner acknowledges this fixture")
		AssertTrue(_I18nCacheLoaded, "the actual locale file must load before menu construction")
		return Body.Call()
	} finally {
		_LBMD_RestoreHardwareLocale(Saved)
	}
}

/** Pins the independent English corpus without persisting a locale or scheduling reload. */
_LBMD_HardwareBoundary() {
	return _LBMD_WithHardwareLocale("en", _LBMD_HardwareBoundaryCurrent)
}

/** The real Windows Map-presence contract remains distinct from the macOS value predicate. */
_LBMD_HardwareBoundaryCurrent() {
	global _SharedDir
	Expected := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\model_hardware_boundary.json", "UTF-8"))
	Model := _LBMD_ReadoutCatalogueModel(Expected["native_model"])
	Name := Model["name"], Url := Model["urls"]["ollama"]
	Hardware := Model["hardware_requirements"]
	AssertEqual("", _LVS_DeepEqual(Expected["hardware_ollama"], Hardware["ollama"]))
	Frame := _MR_GetMenuDef(Expected["section"]), Original := Frame[1]
	Root := _MM_GetManifestRoot(), Native := 0
	try {
		Rows := _LLM_Menu_PerModelRows(Name, Model, Url, Name, false)
		Position := 0
		for Index, Row in Rows
			if Row.Get("label", "") == Expected["header"]["ahk"]
				Position := Index
		Assert(Position > 1, "actual hardware heading must be reached")
		AssertTrue(Rows[Position - 1]["separator"])
		AssertFalse(Rows[Position].Has("action"), "the original Windows hardware header remains inert")
		AssertEqual(StrReplace(t("menu.llm.hw_download"), "%s", Expected["hardware_ollama"]["download_gb"]), Rows[Position + 1]["label"])
		AssertEqual(StrReplace(t("menu.llm.hw_ram"), "%s", Expected["hardware_ollama"]["ram_gb"]), Rows[Position + 2]["label"])
		AssertTrue(HasMethod(Rows[1]["action"], "Call"))
		AssertTrue(HasMethod(Rows[2]["action"], "Call"), "original Download closure remains native")
		Native := Menu()
		MenuRenderer_AppendRows(Native, "llm_menu", "llm_model", Rows)
		State := DllCall("GetMenuState", "ptr", Native.Handle, "uint", Position - 2, "uint", 0x400, "uint")
		Assert(State != 0xFFFFFFFF && (State & 0x800) != 0, "genuine Win32 separator persists")
		Frame[1] := Map("type", "label", "id", "hand_hardware_marker", "i18n", Expected["marker_key"],
			"platforms", ["ahk", "hs"], "unavailable", "hide")
		Rows := _LLM_Menu_PerModelRows(Name, Model, Url, Name, false)
		AssertEqual(t(Expected["marker_key"]), Rows[Position - 1]["label"])
		AssertTrue(Rows[Position - 1]["disabled"])
		AssertFalse(Rows[Position - 1].Has("action"))
		AssertEqual(Expected["header"]["ahk"], Rows[Position]["label"])
		Frame[1] := Map("type", "command", "id", "unbound_hardware_marker", "i18n", Expected["marker_key"])
		AssertEqual(0, _LLM_Menu_PerModelRows(Name, Model, Url, Name, false).Length)
		Root.Delete(Expected["section"])
		AssertEqual(0, _LLM_Menu_PerModelRows(Name, Model, Url, Name, false).Length)
		Root[Expected["section"]] := Frame, Frame[1] := Original
		Model["hardware_requirements"] := Map("ollama", Map())
		Rows := _LLM_Menu_PerModelRows(Name, Model, Url, Name, false)
		Seen := false
		for Row in Rows
			if Row.Get("label", "") == Expected["header"]["ahk"]
				Seen := true
		AssertEqual(Expected["empty_ollama_map_header_visible"]["ahk"], Seen, "an actual empty Map still satisfies original Windows presence")
		Model.Delete("hardware_requirements")
		Rows := _LLM_Menu_PerModelRows(Name, Model, Url, Name, false)
		Seen := false
		for Row in Rows
			if Row.Get("label", "") == Expected["header"]["ahk"]
				Seen := true
		AssertEqual(Expected["missing_hardware_header_visible"]["ahk"], Seen)
	} finally {
		Model["hardware_requirements"] := Hardware
		Root[Expected["section"]] := Frame, Frame[1] := Original
		if Native is Menu
			_CTC_ReleaseMenu(Native)
	}
	Rows := _LLM_Menu_PerModelRows(Name, Model, Url, Name, false)
	AssertTrue(Rows[Position - 1]["separator"], "actual repaired declaration and original data remain usable")
	AssertEqual("", _LVS_DeepEqual(Expected["hardware_ollama"], Model["hardware_requirements"]["ollama"]))
}
Test("per-model hardware: authentic shared boundary and original Map predicate (model-hardware-boundary)",
	_LBMD_HardwareBoundary)


/** Exercises the real picker with genuine catalogue loading and native menu handles. */
_LBMD_ModelHeaderBoundary(Populated) {
	global _SharedDir, _LLM_Menu, LLM_Defaults, _LLM_Deps_State
	Expected := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\model_header_boundary.json", "UTF-8"))
	SavedMenu := _LLM_Menu
	HadDeps := IsSet(_LLM_Deps_State)
	if HadDeps
		SavedDeps := _LLM_Deps_State
	HadDefaults := IsSet(LLM_Defaults)
	if HadDefaults
		SavedDefaults := LLM_Defaults
	Frame := _MR_GetMenuDef(Expected["section"]), Original := Frame[1]
	Root := _MM_GetManifestRoot(), Native := 0
	try {
		_LLM_Menu := Map("backend", "ollama", "model", Populated ? Expected["default_name"] : "")
		LLM_Defaults := Map("llm_model", Populated ? Expected["default_name"] : "")
		_LLM_Deps_State := "pending"
		Assert(LLM_GetModelPresets().Length > 0, "this test loads the actual nonempty shared catalogue")
		Position := Populated ? 3 : 2
		Native := LLM_Menu_BuildModelMenu()
		Label := Buffer(2048, 0)
		DllCall("GetMenuStringW", "ptr", Native.Handle, "uint", 0, "ptr", Label, "int", 1024, "uint", 0x400)
		AssertEqual(t("menu.llm.no_model"), StrGet(Label, "UTF-16"))
		Assert(DllCall("GetMenuItemCount", "ptr", Native.Handle, "int") > Position)
		Flags := DllCall("GetMenuState", "ptr", Native.Handle, "uint", Position - 1, "uint", 0x400, "uint")
		Assert(Flags != 0xFFFFFFFF && (Flags & 0x800) != 0, "the actual header boundary remains a native separator")
		NoModel := DllCall("GetMenuState", "ptr", Native.Handle, "uint", 0, "uint", 0x400, "uint")
		Assert(NoModel != 0xFFFFFFFF && (NoModel & 0x3) == 0, "NoModel remains selectable")
		AssertEqual(!Populated, (NoModel & 0x8) != 0)
		if Populated {
			DllCall("GetMenuStringW", "ptr", Native.Handle, "uint", 1, "ptr", Label, "int", 1024, "uint", 0x400)
			AssertEqual(StrReplace(t("menu.llm.backend_default_model"), "%s", Expected["default_name"]), StrGet(Label, "UTF-16"))
			Default := DllCall("GetMenuState", "ptr", Native.Handle, "uint", 1, "uint", 0x400, "uint")
			Assert(Default != 0xFFFFFFFF && (Default & 0x3) == 0 && (Default & 0x8) != 0)
		}
		_CTC_ReleaseMenu(Native), Native := 0
		Frame[1] := Map("type", "label", "id", "hand_header_marker", "i18n", Expected["marker_key"],
			"platforms", ["ahk", "hs"], "unavailable", "hide")
		Native := LLM_Menu_BuildModelMenu()
		Flags := DllCall("GetMenuState", "ptr", Native.Handle, "uint", Position - 1, "uint", 0x400, "uint")
		DllCall("GetMenuStringW", "ptr", Native.Handle, "uint", Position - 1, "ptr", Label, "int", 1024, "uint", 0x400)
		AssertEqual(t(Expected["marker_key"]), StrGet(Label, "UTF-16"))
		Assert(Flags != 0xFFFFFFFF && (Flags & 0x800) == 0 && (Flags & 0x3) != 0,
			"the actual picker consumes the live inert shared marker")
		_CTC_ReleaseMenu(Native), Native := 0
		Frame[1] := Map("type", "command", "id", "unbound_header_marker", "i18n", Expected["marker_key"])
		Native := LLM_Menu_BuildModelMenu()
		AssertEqual(0, DllCall("GetMenuItemCount", "ptr", Native.Handle, "int"), "unbound header presentation refuses the picker")
		_CTC_ReleaseMenu(Native), Native := 0
		Root.Delete(Expected["section"])
		Native := LLM_Menu_BuildModelMenu()
		AssertEqual(0, DllCall("GetMenuItemCount", "ptr", Native.Handle, "int"), "withdrawn header has no native fallback")
		_CTC_ReleaseMenu(Native), Native := 0
		Root[Expected["section"]] := Frame, Frame[1] := Original
		Native := LLM_Menu_BuildModelMenu()
		Flags := DllCall("GetMenuState", "ptr", Native.Handle, "uint", Position - 1, "uint", 0x400, "uint")
		Assert(Flags != 0xFFFFFFFF && (Flags & 0x800) != 0, "repair retains the original native model picker")
		AssertEqual(Populated ? Expected["default_name"] : "", _LLM_Menu["model"], "construction/refusal never changes model state")
		AssertEqual("pending", _LLM_Deps_State)
	} finally {
		Root[Expected["section"]] := Frame, Frame[1] := Original
		_LLM_Menu := SavedMenu
		if HadDeps
			_LLM_Deps_State := SavedDeps
		else
			_LLM_Deps_State := unset
		if HadDefaults
			LLM_Defaults := SavedDefaults
		else
			LLM_Defaults := unset
		if Native is Menu
			_CTC_ReleaseMenu(Native)
	}
}
for Populated in [false, true]
	Test("model header boundary: genuine picker default " . Populated, _LBMD_ModelHeaderBoundary.Bind(Populated))


/** A callback failure must not retain the fixture's initialized English owner. */
_LBMD_HardwareLocaleThrow() {
	global _SharedDir
	Expected := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\model_hardware_boundary.json", "UTF-8"))
	AssertEqual("en", I18nGetLocale())
	AssertEqual(Expected["header"]["ahk"], StrReplace(t("menu.llm.hw_header"), "%s", "Ollama"))
	throw Error("hardware locale restoration sentinel")
}

/** Exercises successful native construction and throwing callbacks from a real French cohort. */
_LBMD_HardwareLocaleRestorationCurrent(Throws) {
	Saved := _LBMD_HardwareLocaleState()
	AssertEqual("fr", I18nGetLocale())
	if Throws {
		Thrown := false
		try {
			_LBMD_WithHardwareLocale("en", _LBMD_HardwareLocaleThrow)
		} catch as Err {
			AssertEqual("hardware locale restoration sentinel", Err.Message)
			Thrown := true
		}
		AssertTrue(Thrown, "the real callback must throw before restoration is checked")
	} else {
		_LBMD_HardwareBoundary()
	}
	Current := _LBMD_HardwareLocaleState()
	for Index, Value in Saved
		AssertEqual(Value, Current[Index], "successful and throwing fixtures restore locale state " . Index)
}

/** Keeps an independently initialized French owner outside the scoped hardware fixture. */
_LBMD_HardwareLocaleRestoration(Throws) {
	Saved := _LBMD_HardwareLocaleState()
	_LBMD_WithHardwareLocale("fr", _LBMD_HardwareLocaleRestorationCurrent.Bind(Throws))
	Current := _LBMD_HardwareLocaleState()
	for Index, Value in Saved
		AssertEqual(Value, Current[Index], "the outer genuine cohort restores locale state " . Index)
}

/** The original corpus comparison fails under a genuine non-English owner. */
_LBMD_HardwareLocaleOriginalPremiseCurrent() {
	global _SharedDir
	AssertEqual("fr", I18nGetLocale())
	Expected := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\model_hardware_boundary.json", "UTF-8"))
	Model := _LBMD_ReadoutCatalogueModel(Expected["native_model"])
	FrenchHeader := "CONFIGURATION REQUISE (Ollama)"
	AssertEqual(FrenchHeader, StrReplace(t("menu.llm.hw_header"), "%s", "Ollama"))
	Rows := _LLM_Menu_PerModelRows(Model["name"], Model, Model["urls"]["ollama"], Model["name"], false)
	Position := 0
	for Index, Row in Rows
		if Row.Get("label", "") == FrenchHeader
			Position := Index
	Assert(Position > 1, "the genuine French native heading exists before the original English comparison")
	AssertTrue(Rows[Position - 1]["separator"])
	Failure := ""
	try {
		_LBMD_HardwareBoundaryCurrent()
	} catch as Err {
		Failure := Err.Message
	}
	AssertEqual("actual hardware heading must be reached", Failure,
		"the unchanged original body must expose the unbound English premise")
	_LBMD_HardwareBoundary()
	AssertEqual("fr", I18nGetLocale(), "repair restores the genuine French owner after native construction")
}

/** Proves the old premise and repaired native allocator through the same original body. */
_LBMD_HardwareLocaleOriginalPremise() {
	_LBMD_WithHardwareLocale("fr", _LBMD_HardwareLocaleOriginalPremiseCurrent)
}
for Throws in [false, true]
	Test("model hardware locale: genuine owner restoration after throw " . Throws,
		_LBMD_HardwareLocaleRestoration.Bind(Throws))
Test("model hardware locale: unchanged English premise fails in a genuine French cohort",
	_LBMD_HardwareLocaleOriginalPremise)


_LBMD_ModelHeaderDependencyPresence(Present) {
	global _LLM_Deps_State
	HadOriginal := IsSet(_LLM_Deps_State)
	if HadOriginal
		Original := _LLM_Deps_State
	try {
		if Present
			_LLM_Deps_State := "fixture-prior-state"
		else
			_LLM_Deps_State := unset
		_LBMD_ModelHeaderBoundary(false)
		AssertEqual(Present, IsSet(_LLM_Deps_State), "empty default picker restores prior dependency presence")
		if Present
			AssertEqual("fixture-prior-state", _LLM_Deps_State)
		_LBMD_ModelHeaderBoundary(true)
		AssertEqual(Present, IsSet(_LLM_Deps_State), "populated default picker restores prior dependency presence")
		if Present
			AssertEqual("fixture-prior-state", _LLM_Deps_State)
	} finally {
		if HadOriginal
			_LLM_Deps_State := Original
		else
			_LLM_Deps_State := unset
	}
}
for Present in [false, true]
	Test("model header boundary: dependency prior presence " . Present, _LBMD_ModelHeaderDependencyPresence.Bind(Present))


/** Drives each complete sheet through the actual catalogue and Win32 row owner. */
_LBMD_CompleteModelFrame(Section) {
	return _LBMD_WithHardwareLocale("en", _LBMD_CompleteModelFrameCurrent.Bind(Section))
}

_LBMD_CompleteModelFrameCurrent(Section) {
	global _SharedDir
	Expected := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\llm_complete_model_frames.json", "UTF-8"))
	Model := _LBMD_ReadoutCatalogueModel(Expected["native_model"])
	Name := Model["name"], Url := Model["urls"]["ollama"]
	AssertEqual(Expected["raw_source"], Url)
	Root := _MM_GetManifestRoot(), Frame := Root[Section]
	Native := 0
	try {
		Rows := _LLM_Menu_PerModelRows(Name, Model, Url, Name, false)
		AssertEqual(t("menu.llm.select_model"), Rows[1]["label"])
		AssertTrue(HasMethod(Rows[1]["action"], "Call"))
		AssertTrue(HasMethod(Rows[2]["action"], "Call"), "the actual uninstalled Download action stays native")
		AssertTrue(Rows[3]["separator"])
		AssertEqual("Backend: Ollama 🦙", Rows[4]["label"])
		AssertFalse(Rows[4].Has("action"), "Windows backend information remains inert")
		AssertFalse(Rows[4].Has("disabled"), "absent action owns native greying without changing the Map ABI")
		AssertEqual("Source: https://ollama.com/library/qwen3-coder:30b", Rows[5]["label"])
		AssertTrue(HasMethod(Rows[5]["action"], "Call"))
		Native := Menu()
		MenuRenderer_AppendRows(Native, "llm_menu", "llm_model", Rows)
		Flags := DllCall("GetMenuState", "ptr", Native.Handle, "uint", 3, "uint", 0x400, "uint")
		Assert(Flags != 0xFFFFFFFF && (Flags & 0x3) != 0, "actual Win32 backend label is disabled by absent action")
		Root.Delete(Section)
		AssertEqual(0, _LLM_Menu_PerModelRows(Name, Model, Url, Name, false).Length,
			"the real allocator must not reconstruct a withdrawn complete frame")
		Root[Section] := [Map("type", "command", "id", "unbound_complete_model", "i18n", "button.cancel")]
		AssertEqual(0, _LLM_Menu_PerModelRows(Name, Model, Url, Name, false).Length,
			"an unbound declared command cannot become an inert model row")
	} finally {
		Root[Section] := Frame
		if Native is Menu
			_CTC_ReleaseMenu(Native)
	}
	Assert(_LLM_Menu_PerModelRows(Name, Model, Url, Name, false).Length > 0,
		"the repaired declaration consumes the same genuine physical model")
}
for Section in ["llm_model_action_rows", "llm_model_identity_rows", "llm_model_spec_rows",
	"llm_model_capability_rows", "llm_model_hardware_rows"]
	Test("complete model sheet: actual frame " . Section, _LBMD_CompleteModelFrame.Bind(Section))


/** The per-app frame retains lazy native commands and its true empty predicate. */
_LBMD_CompletePerAppFrame() {
	global _LLM_Menu
	Saved := _LLM_Menu
	Root := _MM_GetManifestRoot(), Original := Root["llm_profile_app_override_frame"]
	try {
		_LLM_Menu := Saved.Clone()
		; Match the genuine menu constructor rather than inheriting another fixture's profile array.
		_LLM_Menu["user_profiles"] := []
		_LLM_Menu["app_profile_overrides"] := Map()
		Empty := _LLM_Menu_PerAppProfileRows()
		AssertEqual(1, Empty.Length)
		AssertEqual(t("menu.profiles.override_active_app_with_current"), Empty[1]["label"])
		AssertTrue(HasMethod(Empty[1]["action"], "Call"))
		_LLM_Menu["app_profile_overrides"] := Map("editor.exe", "default")
		Rows := _LLM_Menu_PerAppProfileRows()
		AssertEqual(3, Rows.Length)
		AssertTrue(Rows[2]["separator"])
		AssertEqual("editor.exe  →  " . LLM_Menu_GetProfileLabel("default"), Rows[3]["label"])
		AssertTrue(HasMethod(Rows[3]["action"], "Call"))
		Root.Delete("llm_profile_app_override_frame")
		AssertThrows(_LLM_Menu_PerAppProfileRows, "the actual unowned per-app frame refuses construction")
		Root["llm_profile_app_override_frame"] := [Map("type", "command", "id", "unbound_profile_override", "i18n", "button.cancel")]
		AssertThrows(_LLM_Menu_PerAppProfileRows, "the actual unowned per-app frame refuses construction")
		AssertEqual("default", _LLM_Menu["app_profile_overrides"]["editor.exe"])
	} finally {
		Root["llm_profile_app_override_frame"] := Original
		_LLM_Menu := Saved
	}
}
Test("complete per-app frame: actual empty/populated override owner and strict withdrawal", _LBMD_CompletePerAppFrame)


; The native profile reader legitimately requires assigned canonical profile records.
; Seed a real sparse Array to prove this fixture never inherits another case's holes.
_LBMD_PerAppFrameIsolatesProfiles() {
	global _LLM_Menu
	Saved := _LLM_Menu, Holey := []
	Holey.Length := 1
	try {
		_LLM_Menu := Saved.Clone()
		_LLM_Menu["user_profiles"] := Holey
		Owner := _LLM_Menu
		AssertThrows(LLM_Menu_GetProfileLabel.Bind("default"), "the genuine profile reader rejects an unassigned inherited record")
		_LBMD_CompletePerAppFrame()
		AssertEqual(Owner, _LLM_Menu, "the per-app fixture restores the same prior map")
		AssertEqual(Holey, _LLM_Menu["user_profiles"], "the per-app fixture restores the same prior profile array")
		AssertFalse(Holey.Has(1), "the fixture cannot fill or mutate the borrowed sparse array")
	} finally _LLM_Menu := Saved
}
Test("per-app fixture: isolate canonical profiles and restore the genuine borrowed sparse array",
	_LBMD_PerAppFrameIsolatesProfiles)
