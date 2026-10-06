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
	AssertContains(Tail, '"action", (*) => LLM_Menu_PromptAddModel()', "original Add dialog callback body remains native")
	AssertContains(Tail, '_LLM_Menu_ModelBrowserRow()', "original browser admission owner remains native")
	Assert(InStr(Tail, 'Map("separator", true)') == 0, "no native fallback separator may replace a refused declaration")
}
Test("models picker: actual model-menu consumer retains native owners and shared boundary",
	_LBMD_ModelPickerBoundaryConsumer)
