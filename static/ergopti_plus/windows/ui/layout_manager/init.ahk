; ui/layout_manager/init.ahk

; ==============================================================================
; MODULE: Layout Manager WebView2 Host
; DESCRIPTION:
; Hosts the shared layout manager page (_shared/ui/layout_manager) on Windows
; through WebView2: the "Manage layouts…" row of the keyboard-layout submenu
; opens it, and it lists, installs, updates, uninstalls and selects the
; layouts of the registry through modules/keymap/keylayout/layout_catalogue.ahk.
;
; FEATURES & RATIONALE:
; 1. The same rules as the macOS and Linux hosts
;    (_shared/lua/layouts/manager_bridge.lua): an allowlist of actions, each
;    checked against the catalogue or the installed layouts before it runs,
;    and one page state for the three drivers.
; 2. Selecting a layout writes [layout] emulated_layout (the Ergopti layouts
;    select the built-in emulation instead) and reloads, the only moment the
;    emulation registers its hotkeys.
; 3. Singleton window; every WebView2 callback is fenced by a session epoch,
;    so a late callback of a closed window never writes into its successor.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================
; ====================================
; ======= 1/ State and actions =======
; ====================================
; ====================================

global _LayMgrWeb_Gui        := 0
global _LayMgrWeb_Controller := unset
global _LayMgrWeb_WebView    := unset
global _LayMgrWeb_MsgSub     := unset
global _LayMgrWeb_NavSub     := unset
global _LayMgrWeb_ResetDone  := false
global _LayMgrWeb_SessionEpoch := 0
global _LayMgrWeb_ReadyEpoch := 0
; Result of the last operation, shown by the page (0 when none).
global _LayMgrWeb_Result := 0
; A durable catalogue operation still waits for its terminal runtime refresh.
global _LayMgrWeb_RuntimeRefresh := 0

; Virtual host mapped to _SharedDir (apps.manifest.json).
global LAYMGR_VHOST := "ergopti.layoutmanager"
global LAYMGR_HOST_ACCESS_ALLOW := 1

; The only actions the page may send (the page and the Lua hosts declare the
; same list; tools/test/test-layout-manager-page.cjs pins the three).
global LAYMGR_ACTIONS := Map("ready", true, "refresh", true, "install", true, "update", true,
	"uninstall", true, "select", true, "open_homepage", true, "close", true)





; =============================
; =============================
; ======= 2/ Page state =======
; =============================
; =============================

/**
 * The Ergopti registry layouts the built-in emulation provides.
 * @returns {Map} Registry id -> true.
 */
LayoutManager_BuiltinIds() {
	global ERGOPTI_LAYOUT_ID, ERGOPTI_PLUS_LAYOUT_ID
	return Map(ERGOPTI_LAYOUT_ID, true, ERGOPTI_PLUS_LAYOUT_ID, true)
}

/**
 * The registry id of the layout typing uses now: the emulated registry layout,
 * the built-in Ergopti emulation (Ergopti or Ergopti+), or "" for the system's.
 * @param {Map} FeaturesSource - Features Map to read; the live one by default.
 * @returns {string}
 */
LayoutManager_ActiveId(FeaturesSource := unset) {
	global Features, ERGOPTI_LAYOUT_ID, ERGOPTI_PLUS_LAYOUT_ID
	if !IsSet(FeaturesSource) {
		if !IsSet(Features)
			return ""
		FeaturesSource := Features
	}
	Selected := KeylayoutEmulation_SelectedId(FeaturesSource)
	if (Selected != "")
		return Selected
	Layout := FeaturesSource.Has("layout") ? FeaturesSource["layout"] : Map()
	if !(Layout.Get("ergopti_base", false) = true)
		return ""
	return ErgoptiLayout_BuiltinVariant(FeaturesSource)
}

; JSON of the page state. JSON_NULL stands for none.
_LayMgrWeb_Json(Value) {
	global JSON_NULL
	if (Value == JSON_NULL)
		return "null"
	if (Value is Map) {
		Out := ""
		for Key, Item in Value
			Out .= (A_Index > 1 ? "," : "") . JsonStringLiteral(Key) . ":" . _LayMgrWeb_Json(Item)
		return "{" . Out . "}"
	}
	if (Value is Array) {
		Out := ""
		for Item in Value
			Out .= (A_Index > 1 ? "," : "") . _LayMgrWeb_Json(Item)
		return "[" . Out . "]"
	}
	if (Value is Integer) || (Value is Float)
		return String(Value)
	return JsonStringLiteral(Value)
}

/**
 * The state the page renders (the shape every host sends).
 * @param {string} LocalDir - Folder from LayoutRegistry_LocalDir; the configured one by default.
 * @returns {Map}
 */
LayoutManager_PageState(LocalDir := unset) {
	global _ConfigDir, _LayMgrWeb_Result, JSON_NULL, LAYOUT_CATALOGUE_SOURCE_BUNDLED
	if !IsSet(LocalDir)
		LocalDir := LayoutRegistry_LocalDir(_ConfigDir)
	Last := LayoutCatalogue_Last()
	Index := Last["index"]
	Source := Last["source"]
	if !(Index is Map) {
		; Before the first refresh the page lists the index shipped with the
		; driver, and says so rather than "no catalogue".
		Index := LayoutCatalogue_BundledIndex()
		if (Index is Map)
			Source := LAYOUT_CATALOGUE_SOURCE_BUNDLED
	}
	RecordError := JSON_NULL
	try Installed := LayoutCatalogue_ReadInstalled(LocalDir)
	catch as Err {
		Installed := Map()
		RecordError := Err.Message
	}
	global _LayMgrWeb_RuntimeRefresh
	Busy := (_LayMgrWeb_RuntimeRefresh is Map) ? _LayMgrWeb_RuntimeRefresh : LayoutCatalogue_Busy()
	return Map(
		"platform", LAYOUT_CATALOGUE_PLATFORM,
		"index", (Index is Map) ? Index : JSON_NULL,
		"source", Source,
		"error", (Last["error"] is Map) ? Last["error"] : JSON_NULL,
		"installed", Installed,
		"provided", Map(),
		"builtin", LayoutManager_BuiltinIds(),
		"active", LayoutManager_ActiveId(),
		"busy", (Busy is Map) ? Busy : JSON_NULL,
		"result", (_LayMgrWeb_Result is Map) ? _LayMgrWeb_Result : JSON_NULL,
		"record_error", RecordError
	)
}

; The translated strings the page shows (strings.json next to the page).
_LayMgrWeb_Strings() {
	global _SharedDir
	Path := _SharedDir . "\ui\layout_manager\strings.json"
	Text := FSRead(Path)
	if !(Text is String)
		throw Error("Cannot read " . Path)
	Strings := Map()
	for Key in JsonParse(Text)["keys"]
		Strings[Key] := t(Key)
	return Strings
}





; ==========================
; ==========================
; ======= 3/ Actions =======
; ==========================
; ==========================

/**
 * Handles one page message. Anything outside LAYMGR_ACTIONS, or naming a
 * layout the catalogue or the installed record does not know, is refused.
 * @param {Map} Payload - Decoded message.
 * @param {Map} Deps - "local_dir", "push" (FunctionName, Payload), "install",
 *   "uninstall", "select", "refresh", "open_url", "close"; the production ones by default.
 * @returns {boolean} Whether the message was accepted.
 */
LayoutManager_HandleMessage(Payload, Deps := 0) {
	global LAYMGR_ACTIONS, _LayMgrWeb_Result, _LayMgrWeb_RuntimeRefresh
	if !(Deps is Map)
		Deps := _LayMgrWeb_DefaultDeps()
	if !(Payload is Map) || !Payload.Has("action") || !(Payload["action"] is String)
			|| !LAYMGR_ACTIONS.Has(Payload["action"]) {
		LoggerWarn("LayoutManager", "Refused a layout manager message outside the allowlist.")
		return false
	}
	Action := Payload["action"]
	if (_LayMgrWeb_RuntimeRefresh is Map) && (Action == "install" || Action == "update"
			|| Action == "uninstall" || Action == "select") {
		LoggerWarn("LayoutManager", "Refused a layout mutation while runtime refresh is pending.")
		return false
	}
	if (Action == "ready") {
		_LayMgrWeb_Result := 0
		Deps["push"].Call("initData", Map("strings", _LayMgrWeb_Strings(), "state", LayoutManager_PageState(Deps["local_dir"])))
		Deps["refresh"].Call(_LayMgrWeb_PushState.Bind(Deps))
		return true
	}
	if (Action == "refresh") {
		Deps["refresh"].Call(_LayMgrWeb_PushState.Bind(Deps))
		return true
	}
	if (Action == "close") {
		Deps["close"].Call()
		return true
	}
	Id := Payload.Has("id") ? Payload["id"] : ""
	if !LayoutRegistry_IsValidId(Id) {
		LoggerWarn("LayoutManager", "Refused a layout manager '{1}' without a valid layout id.", Action)
		return false
	}
	State := LayoutManager_PageState(Deps["local_dir"])
	Entry := LayoutCatalogue_Entry(State["index"], Id)
	if (Action == "open_homepage") {
		Source := (Entry is Map) ? Entry : State["installed"].Get(Id, 0)
		Homepage := (Source is Map) ? Source.Get("homepage", "") : ""
		if !RegExMatch(Homepage, "^https://\S+$") {
			LoggerWarn("LayoutManager", "Refused to open the homepage of '{1}': none is published over https.", Id)
			return false
		}
		Deps["open_url"].Call(Homepage)
		return true
	}
	if (Action == "install" || Action == "update") {
		if !(Entry is Map) {
			LoggerWarn("LayoutManager", "Refused to {1} '{2}': the catalogue does not list it.", Action, Id)
			return false
		}
		Deps["install"].Call(Id, _LayMgrWeb_OnDone.Bind(Deps, Id, Action))
		_LayMgrWeb_PushState(Deps)
		return true
	}
	if (Action == "select" && State["builtin"].Has(Id)) {
		Deps["select"].Call(Id)
		return true
	}
	if !State["installed"].Has(Id) {
		LoggerWarn("LayoutManager", "Refused to {1} '{2}': it is not installed.", Action, Id)
		return false
	}
	if (Action == "uninstall") {
		Outcome := Deps["uninstall"].Call(Id)
		_LayMgrWeb_OnDone(Deps, Id, Action, Outcome["ok"], Outcome.Get("code", ""), Outcome.Get("detail", ""))
		return true
	}
	Deps["select"].Call(Id)
	return true
}

_LayMgrWeb_OnDone(Deps, Id, Action, Ok, CodeOrDetail := "", Detail := "") {
	global _LayMgrWeb_Result, _LayMgrWeb_RuntimeRefresh
	if !Ok {
		_LayMgrWeb_Result := Map("id", Id, "action", Action, "ok", false, "code", String(CodeOrDetail),
			"detail", String(Detail))
		_LayMgrWeb_PushState(Deps)
		return false
	}
	if !Deps.Has("after") {
		_LayMgrWeb_Result := Map("id", Id, "action", Action, "ok", true)
		_LayMgrWeb_PushState(Deps)
		return true
	}
	Pending := Map("id", Id, "action", Action)
	_LayMgrWeb_RuntimeRefresh := Pending
	_LayMgrWeb_Result := 0
	_LayMgrWeb_PushState(Deps)
	Finish(Ready) {
		global _LayMgrWeb_Result, _LayMgrWeb_RuntimeRefresh
		if _LayMgrWeb_RuntimeRefresh != Pending
			return false
		_LayMgrWeb_RuntimeRefresh := 0
		Accepted := (Ready is Integer) && Ready == 1
		_LayMgrWeb_Result := Map("id", Id, "action", Action, "ok", Accepted)
		if !Accepted
			_LayMgrWeb_Result["code"] := "other"
		_LayMgrWeb_PushState(Deps)
		return true
	}
	try Started := Deps["after"].Call(Id, Action, Finish)
	catch as Err {
		LoggerError("LayoutManager", "Runtime refresh failed after catalogue publication: {1}.", Err.Message)
		Started := false
	}
	if !(Started is Integer) || Started != 1 {
		Finish(false)
		return false
	}
	return true
}

_LayMgrWeb_PushState(Deps, *) {
	Deps["push"].Call("updateState", LayoutManager_PageState(Deps["local_dir"]))
}

/**
 * Selects a layout through the acknowledged configuration handoff.
 * @param {String} Id Registry layout identifier.
 * @param {Map} Options Configuration lifecycle ports for owner tests.
 * @returns {Boolean} Whether the successor launch was accepted.
 */
LayoutManager_Select(Id, Options := unset) {
	Receipt := IsSet(Options) ? LayoutManager_SelectTransition(Id, Options) : LayoutManager_SelectTransition(Id)
	return Receipt["status"] == "pending" || Receipt["status"] == "committed"
}

/**
 * Retains the selected configuration until successor completion or rollback.
 * The resident input owner keeps its admitted layout while the reload is pending.
 * @param {String} Id Registry layout identifier.
 * @param {Map} Options Configuration lifecycle ports for owner tests.
 * @returns {Map} Pending or terminal configuration receipt.
 */
LayoutManager_SelectTransition(Id, Options := unset) {
	if !LayoutRegistry_IsValidId(Id)
		throw ValueError("The layout selection requires a valid registry identifier.")
	if !IsSet(Options)
		Options := Map()
	if !(Options is Map)
		throw TypeError("The layout selection requires explicit lifecycle options.")
	global ConfigurationFile
	Path := Options.Has("path") ? Options["path"] : ConfigurationFile
	SnapshotFn := Options.Get("snapshot_fn", _LayMgrWeb_BuiltinVariantSnapshot)
	if !HasMethod(SnapshotFn, "Call")
		throw TypeError("The selected helper source requires a callable intent witness.")
	Expected := Options.Has("expected") ? Options["expected"] : SnapshotFn.Call(Path)
	LoggerInfo("LayoutManager", "Selecting the '{1}' layout through the owned reload handoff.", Id)
	return ConfigScopeCommitOperations("keyboard_layout", "select",
		_LayMgrWeb_SelectionOperations.Bind(Id, Path, Expected, SnapshotFn), Options)
}

; Built-in selections keep the existing empty-emulation contract and overlays.
; A registry selection changes only its source identifier; it owns no layer gate.
_LayMgrWeb_SelectionOperations(Id, Path, Expected, SnapshotFn) {
	global ERGOPTI_PLUS_LAYOUT_ID
	Current := SnapshotFn.Call(Path)
	if !(Expected is Map) || !(Current is Map)
			|| !Expected.Get("valid", false) || !Current.Get("valid", false)
			|| Expected.Get("path", "") != Path || Current.Get("path", "") != Path
			|| Expected["presence"] != Current["presence"]
			|| StrCompare(Expected["content"], Current["content"], true) != 0
			|| !ManifestValuesEqual(Expected["values"], Current["values"])
		throw Error("The selected helper source intent changed or could not be admitted.")
	if LayoutManager_BuiltinIds().Has(Id)
		return [
			ManifestSparseOperation("layout.emulated_layout", ""),
			ManifestSparseOperation("layout.ergopti_base", true),
			ManifestSparseOperation("layout.ergopti_variant", Id),
		]
	return [ManifestSparseOperation("layout.emulated_layout", Id)]
}

; The successor discovers committed extension roots even for nonselected layouts.
; A launch acknowledgement is deliberately separate from terminal completion.
_LayMgrWeb_After(Id, Action, OnDone, Options := unset) {
	global Features, _ConfigDir, _HotstringExtensionPacks
	if !IsSet(Options)
		Options := Map()
	LocalDir := Options.Has("local_dir") ? Options["local_dir"] : LayoutRegistry_LocalDir(_ConfigDir)
	Selected := Options.Get("selected", KeylayoutEmulation_SelectedId).Call() == Id
	Packs := Options.Has("packs") ? Options["packs"].Call() : _HotstringExtensionPacks
	NeedsRefresh := Selected
	for Pack in Packs {
		if Pack.id == Id
			NeedsRefresh := true
	}
	Installed := LayoutCatalogue_ReadInstalled(LocalDir)
	if Installed.Has(Id) && Installed[Id].Has("extension")
		NeedsRefresh := true
	if !NeedsRefresh {
		OnDone.Call(true)
		return true
	}
	if Selected && Action == "uninstall" {
		LoggerInfo("LayoutManager", "The emulated '{1}' layout was uninstalled; back to the system layout.", Id)
		WriteSelection := Options.Get("write_selection", (Value) => WriteFeatureV2(Features, "layout.emulated_layout", Value))
		if !WriteSelection.Call("")
			return ConfigReportPersistenceFailure("the layout selection")
	}
	Refused(Reason) {
		LoggerError("LayoutManager", "Runtime refresh refused after catalogue publication: {1}.", Reason)
		OnDone.Call(false)
	}
	ReloadFn := Options.Get("reload", ReloadPreservingSuspend)
	Started := ReloadFn.Call((*) => OnDone.Call(true), 0, Refused)
	if !(Started is Integer) || Started != 1 {
		OnDone.Call(false)
		return false
	}
	return true
}

_LayMgrWeb_DefaultDeps() {
	global _ConfigDir
	return Map(
		"local_dir", LayoutRegistry_LocalDir(_ConfigDir),
		"push", _LayMgrWeb_Push,
		"refresh", (OnDone) => LayoutCatalogue_Refresh(LayoutRegistry_LocalDir(_ConfigDir), OnDone),
		"install", (Id, OnDone) => LayoutCatalogue_Install(Id, LayoutRegistry_LocalDir(_ConfigDir), OnDone),
		"uninstall", (Id) => LayoutCatalogue_Uninstall(Id, LayoutRegistry_LocalDir(_ConfigDir)),
		"select", LayoutManager_Select,
		"open_url", (Url) => ExternalUrl_OpenHttp(Url),
		"close", _LayMgrWeb_Close,
		"after", _LayMgrWeb_After
	)
}





; ===================================
; ===================================
; ======= 4/ Window lifecycle =======
; ===================================
; ===================================

_LayMgrWeb_Available() {
	global _VendorDir
	return IsSet(WebView2) && FileExist(_VendorDir . "\64bit\WebView2Loader.dll")
}

/**
 * Creates the native layout window before attaching its WebView controller.
 * @returns {Gui} The window with the shared-policy translated caption.
 */
_LayMgrWeb_NewWindow() {
	return Gui_Create("+Resize +MinSize560x400", t("layout_manager.window_title"))
}

/**
 * Opens the layout manager, or focuses it when it is already open.
 * @returns {boolean} Whether the window is shown.
 */
LayoutManager_Open(*) {
	global _LayMgrWeb_Gui, _LayMgrWeb_Controller, _LayMgrWeb_WebView, _LayMgrWeb_MsgSub, _LayMgrWeb_NavSub
	global _LayMgrWeb_ResetDone, _LayMgrWeb_SessionEpoch, _VendorDir, _SharedDir, LAYMGR_VHOST
	global LAYMGR_HOST_ACCESS_ALLOW
	if !_LayMgrWeb_Available() {
		LoggerError("LayoutManager", "The layout manager needs the WebView2 runtime, which is unavailable.")
		Ui_MsgBox(t("layout_manager.failure_other"), t("layout_manager.window_title"), "Iconx")
		return false
	}
	if (_LayMgrWeb_Gui != 0) {
		WMPresentWindow(_LayMgrWeb_Gui)
		return true
	}
	LoggerStart("LayoutManager", "Opening the layout manager…")
	_LayMgrWeb_SessionEpoch += 1
	SessionEpoch := _LayMgrWeb_SessionEpoch
	_LayMgrWeb_ResetDone := false
	g := _LayMgrWeb_NewWindow()
	g.BackColor := "0x1e1e1e"
	g.MarginX := 0
	g.MarginY := 0
	Placeholder := g.Add("Text", "x0 y0 w720 h560", "")
	g.OnEvent("Close", _LayMgrWeb_SessionCall.Bind(SessionEpoch, _LayMgrWeb_Close))
	g.OnEvent("Size", _LayMgrWeb_SessionCall.Bind(SessionEpoch, _LayMgrWeb_OnResize))
	; Shown before the control: a hidden Gui has a zero client rect.
	g.Show("w720 h560 Center")
	_LayMgrWeb_Gui := g
	try {
		_LayMgrWeb_Controller := WebView2.create(Placeholder.Hwnd, , WebView_SharedEnvironment(_VendorDir . "\64bit\WebView2Loader.dll"))
	} catch as Err {
		LoggerError("LayoutManager", "WebView2 create failed: {1}", Err.Message)
		_LayMgrWeb_Close()
		return false
	}
	_LayMgrWeb_WebView := _LayMgrWeb_Controller.CoreWebView2
	try {
		s := _LayMgrWeb_WebView.Settings
		s.AreDevToolsEnabled := false
		s.AreDefaultContextMenusEnabled := false
		s.IsStatusBarEnabled := false
		s.AreBrowserAcceleratorKeysEnabled := false
		s.IsSwipeNavigationEnabled := false
	}
	; Subscription handles live in globals so they are not collected, which
	; would silently drop the JS->AHK channel.
	_LayMgrWeb_MsgSub := _LayMgrWeb_WebView.WebMessageReceived(_LayMgrWeb_OnWebMessage.Bind(SessionEpoch))
	_LayMgrWeb_NavSub := _LayMgrWeb_WebView.NavigationCompleted(_LayMgrWeb_OnNavigationCompleted.Bind(SessionEpoch))
	_LayMgrWeb_WebView.SetVirtualHostNameToFolderMapping(LAYMGR_VHOST, _SharedDir, LAYMGR_HOST_ACCESS_ALLOW)
	_LayMgrWeb_WebView.Navigate("https://" . LAYMGR_VHOST . "/ui/layout_manager/index.html?cb=" . A_TickCount)
	_LayMgrWeb_Controller.Fill()
	LoggerSuccess("LayoutManager", "Layout manager opened.")
	return true
}

_LayMgrWeb_OnWebMessage(SessionEpoch, Handler, Args) {
	global _LayMgrWeb_SessionEpoch
	if (SessionEpoch != _LayMgrWeb_SessionEpoch)
		return
	try Msg := Args.TryGetWebMessageAsString()
	catch as Err {
		LoggerWarn("LayoutManager", "Unreadable layout manager message: {1}", Err.Message)
		return
	}
	try Payload := JsonParse(Msg)
	catch {
		LoggerWarn("LayoutManager", "Refused a layout manager message that is not JSON.")
		return
	}
	; A COM callback bypasses Suspend: a paused driver must not install or
	; reload from a page click, but the page's own ready signal still loads it.
	if A_IsSuspended && !((Payload is Map) && Payload.Get("action", "") == "ready")
		return
	SetTimer(_LayMgrWeb_SessionCall.Bind(SessionEpoch, LayoutManager_HandleMessage, Payload), -1)
}

_LayMgrWeb_OnNavigationCompleted(SessionEpoch, Handler, Args) {
	SetTimer(_LayMgrWeb_SessionCall.Bind(SessionEpoch, LayoutManager_HandleMessage, Map("action", "ready")), -1)
}

_LayMgrWeb_SessionCall(SessionEpoch, Callback, Params*) {
	global _LayMgrWeb_SessionEpoch, _LayMgrWeb_ReadyEpoch
	if (SessionEpoch != _LayMgrWeb_SessionEpoch)
		return false
	IsReady := Callback == LayoutManager_HandleMessage && Params.Length > 0
		&& Params[1] is Map && Params[1].Get("action", "") == "ready"
	if IsReady {
		if _LayMgrWeb_ReadyEpoch == SessionEpoch
			return false
		; Claim before dispatch: both native navigation and the page emit ready.
		_LayMgrWeb_ReadyEpoch := SessionEpoch
	}
	try Callback(Params*)
	catch as Err {
		if IsReady && _LayMgrWeb_ReadyEpoch == SessionEpoch
			_LayMgrWeb_ReadyEpoch := 0
		throw Err
	}
	return true
}

; Fire-and-forget push to the page; the window may already be gone.
_LayMgrWeb_Push(FunctionName, Payload) {
	global _LayMgrWeb_WebView
	if !IsSet(_LayMgrWeb_WebView)
		return false
	WebView_RunScriptAsync(_LayMgrWeb_WebView,
		"if(window." . FunctionName . ")window." . FunctionName . "(" . _LayMgrWeb_Json(Payload) . ")", "LayoutManager")
	return true
}

_LayMgrWeb_OnResize(GuiObj, MinMax, Width, Height) {
	global _LayMgrWeb_Controller
	if (MinMax == -1)
		return
	if IsSet(_LayMgrWeb_Controller)
		try _LayMgrWeb_Controller.Fill()
}

_LayMgrWeb_Close(*) {
	global _LayMgrWeb_Gui
	Owned := _LayMgrWeb_Gui
	_LayMgrWeb_Reset()
	_LayMgrWeb_Gui := 0
	if Owned
		try Owned.Destroy()
}

; Releases the subscriptions while the controller is alive, then closes it;
; idempotent, because the page's close and the window's Close event both come here.
_LayMgrWeb_Reset() {
	global _LayMgrWeb_Controller, _LayMgrWeb_WebView, _LayMgrWeb_MsgSub, _LayMgrWeb_NavSub
	global _LayMgrWeb_ResetDone, _LayMgrWeb_SessionEpoch
	if _LayMgrWeb_ResetDone
		return
	_LayMgrWeb_ResetDone := true
	_LayMgrWeb_SessionEpoch += 1
	try {
		_LayMgrWeb_MsgSub := unset
		_LayMgrWeb_NavSub := unset
		if IsSet(_LayMgrWeb_Controller)
			_LayMgrWeb_Controller.Close()
	}
	_LayMgrWeb_Controller := unset
	_LayMgrWeb_WebView := unset
}

; Snapshot both typed variant and independent source/layer intent without mutating them.
_LayMgrWeb_BuiltinVariantSnapshot(Path) {
	Snapshot := Map("path", Path, "valid", false, "presence", false, "content", "", "values", Map())
	try {
		Snapshot["presence"] := FSStrictExists(Path)
		Snapshot["content"] := Snapshot["presence"] ? FSReadUtf8Exact(Path) : ""
		if !(Snapshot["content"] is String)
			return Snapshot
		Document := TOML_ParseDocument(Snapshot["content"])
		Legacy := _TOML_DocumentLookup(Document, ["layout", "ergopti_plus"])
		if Legacy["found"] || Legacy["blocked"]
			return Snapshot
		for Field in ["layout.ergopti_variant", "layout.emulated_layout", "layout.ergopti_base",
			"layout.ergopti_alt_gr", "category_enabled.layout"] {
			Read := _TOML_DocumentLookup(Document, StrSplit(Field, "."))
			if Read["blocked"]
				return Snapshot
			Value := Read["found"] ? Read["value"] : ManifestDefaultFor(Field)
			if Field == "layout.ergopti_base" || Field == "layout.ergopti_alt_gr" || Field == "category_enabled.layout" {
				if Read["found"] && !(Value is TOML_Bool)
					return Snapshot
				if Value is TOML_Bool
					Value := Value.Value
			} else if Field == "layout.ergopti_variant" {
				if !(Value is String) || (StrCompare(Value, "none", true) != 0 && StrCompare(Value, "ergopti", true) != 0 && StrCompare(Value, "ergopti_plus", true) != 0)
					return Snapshot
			} else if !(Value is String) || (Value != "" && !LayoutRegistry_IsValidId(Value))
				return Snapshot
			Snapshot["values"][Field] := Value
		}
		Snapshot["valid"] := _TOML_WriteSourceMatches(Path, Snapshot["presence"], Snapshot["content"])
	} catch {
		Snapshot["valid"] := false
	}
	return Snapshot
}
