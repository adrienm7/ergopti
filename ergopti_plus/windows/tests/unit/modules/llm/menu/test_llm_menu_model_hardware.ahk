; tests/unit/modules/llm/menu/test_llm_menu_model_hardware.ahk

; ==============================================================================
; MODULE: LLM Menu Model Hardware and Frames
; DESCRIPTION:
; Per-model hardware rows keep the shared boundary and the original Map
; predicate, the model header and its locale owners are restored after a
; throw, and complete model and per-app frames keep their lazy commands.
; ==============================================================================

#Requires AutoHotkey v2.0





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
/** Registers complete frames without publishing a global loop variable. */
_LBMD_RegisterCompleteModelFrames() {
	local Section
	for Section in ["llm_model_action_rows", "llm_model_identity_rows", "llm_model_spec_rows",
		"llm_model_capability_rows", "llm_model_hardware_rows"]
		Test("complete model sheet: actual frame " . Section, _LBMD_CompleteModelFrame.Bind(Section))
}
_LBMD_RegisterCompleteModelFrames()


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
