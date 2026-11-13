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
;    (_shared/layouts/engine/manager_bridge.lua): an allowlist of actions, each
;    checked against the catalogue or the installed layouts before it runs,
;    and one page state for the three drivers.
; 2. Selecting a layout writes [layout] emulated_layout (the Ergopti layouts
;    select the built-in emulation instead) and reloads, the only moment the
;    emulation registers its hotkeys.
; 3. Singleton window; every WebView2 callback is fenced by a session epoch,
;    so a late callback of a closed window never writes into its successor.
; 4. The unified layout editor (docs/design/layout-editor.md « Windows host »)
;    mounts in the same page: source_open and source_save go to source_store.ahk,
;    composer_save with a source and composer_emulate to composer.ahk, nav_save
;    to the navigation layer editor's own save. initData says so with
;    source_editor, emulate and nav_apply; WebView2's own file chooser opens
;    files, so source_pick is refused here.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\..\_generated\config_keys.ahk





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
; An in-flight subscription must return before its controller and HWND retire.
global _LayMgrWeb_SubscriptionOwner := 0
global _LayMgrWeb_RetiredHosts := []
; The current presentation owns its own paths and push port.
global _LayMgrWeb_PresentationDeps := 0
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
	"uninstall", true, "select", true, "open_homepage", true, "close", true,
	"composer_open", true, "composer_save", true, "composer_remove", true, "composer_emulate", true,
	"source_open", true, "source_save", true, "source_pick", true, "nav_save", true)

; The actions that change the installed or selected layout, refused while a
; runtime refresh is pending.
global LAYMGR_MUTATIONS := Map("install", true, "update", true, "uninstall", true, "select", true,
	"composer_save", true, "composer_remove", true, "composer_emulate", true, "nav_save", true)

; A JSON boolean: AutoHotkey's true is the integer 1, which the page's strict
; `=== true` would read as a number.
class LayMgrJsonBool {
	__New(Value) {
		this.Value := Value ? true : false
	}
}

global LAYMGR_JSON_TRUE := LayMgrJsonBool(true)
global LAYMGR_JSON_FALSE := LayMgrJsonBool(false)

/**
 * The JSON boolean of a truth value.
 * @param {Any} Value
 * @returns {LayMgrJsonBool}
 */
LayMgrJsonBool_Of(Value) {
	global LAYMGR_JSON_TRUE, LAYMGR_JSON_FALSE
	return Value ? LAYMGR_JSON_TRUE : LAYMGR_JSON_FALSE
}

; The menu asked for the editor: the next ready answers as source_open does.
global _LayMgrWeb_EditorWanted := false





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
	if !(Layout.Get(ConfigLeaf.ERGOPTI_BASE, false) = true)
		return ""
	return ErgoptiLayout_BuiltinVariant(FeaturesSource)
}

; JSON of the page state. JSON_NULL stands for none.
_LayMgrWeb_Json(Value) {
	global JSON_NULL
	if (Value == JSON_NULL)
		return "null"
	if Value is LayMgrJsonBool
		return Value.Value ? "true" : "false"
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
	; shortcut_menu_path: the extension file this driver loads as a layout's
	; shortcut menu (ui/menu/menu_shortcuts.ahk); the page counts it and never
	; derives it from the platform.
	return Map(
		"platform", LAYOUT_CATALOGUE_PLATFORM,
		"shortcut_menu_path", "shortcuts/menu.ahk",
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
 * @param {Integer} SessionEpoch - The scheduling session; the current one for direct callers.
 * @returns {boolean} Whether the message was accepted.
 */
LayoutManager_HandleMessage(Payload, Deps := 0, SessionEpoch := unset) {
	global LAYMGR_ACTIONS, _LayMgrWeb_Result, _LayMgrWeb_RuntimeRefresh, _LayMgrWeb_SessionEpoch
	global _LayMgrWeb_PresentationDeps
	if !IsSet(SessionEpoch)
		SessionEpoch := _LayMgrWeb_SessionEpoch
	if !(Payload is Map) || !Payload.Has("action") || !(Payload["action"] is String)
			|| !LAYMGR_ACTIONS.Has(Payload["action"]) {
		LoggerWarn("LayoutManager", "Refused a layout manager message outside the allowlist.")
		return false
	}
	Action := Payload["action"]
	if !_LayMgrWeb_CommandCurrent(SessionEpoch, Action)
		return false
	if !(Deps is Map)
		Deps := _LayMgrWeb_DefaultDeps()
	if !_LayMgrWeb_CommandCurrent(SessionEpoch, Action)
		return false
	; Each retained callback owns the admitting page, even when Deps is reused.
	Deps := Deps.Clone()
	Deps["session_epoch"] := SessionEpoch
	_LayMgrWeb_PresentationDeps := Deps
	global LAYMGR_MUTATIONS, _LayMgrWeb_EditorWanted
	if (_LayMgrWeb_RuntimeRefresh is Map) && LAYMGR_MUTATIONS.Has(Action) {
		LoggerWarn("LayoutManager", "Refused a layout mutation while runtime refresh is pending.")
		return false
	}
	if (Action == "ready") {
		_LayMgrWeb_Result := 0
		; The page mounts the layout editor only for a host that stores its files.
		Initial := Map("strings", _LayMgrWeb_Strings(), "state", LayoutManager_PageState(Deps["local_dir"]),
			"source_editor", LayMgrJsonBool_Of(true), "source_pick", LayMgrJsonBool_Of(false),
			"nav_apply", LayMgrJsonBool_Of(true), "emulate", LayMgrJsonBool_Of(true))
		if !_LayMgrWeb_CommandCurrent(SessionEpoch, Action)
			return false
		_LayMgrWeb_PushPayload(Deps, "initData", Initial)
		if !_LayMgrWeb_CommandCurrent(SessionEpoch, Action)
			return false
		Deps["refresh"].Call(_LayMgrWeb_PushState.Bind(Deps))
		if _LayMgrWeb_EditorWanted {
			_LayMgrWeb_EditorWanted := false
			_LayMgrWeb_SourceOpen(Deps)
		}
		return true
	}
	if (Action == "source_open") {
		_LayMgrWeb_SourceOpen(Deps)
		return true
	}
	if (Action == "source_save") {
		if !(Payload.Get("filename", 0) is String) || !(Payload.Get("text", 0) is String) {
			LoggerWarn("LayoutManager", "Refused a layout editor save without its file name and text.")
			return false
		}
		Result := SourceStore_Save(SourceStore_SharedSettings(), _LayMgrWeb_ConfigDir(Deps),
			Map("filename", Payload["filename"], "text", Payload["text"]), Deps.Get("source_ports", 0))
		Result["ok"] := LayMgrJsonBool_Of(Result["ok"])
		_LayMgrWeb_PushPayload(Deps, "sourceResult", Result)
		return true
	}
	if (Action == "source_pick") {
		LoggerWarn("LayoutManager", "Refused a layout editor file pick: this host lets the page pick files.")
		return false
	}
	if (Action == "nav_save") {
		if !(Payload.Get("text", 0) is String) {
			LoggerWarn("LayoutManager", "Refused a navigation layer save without its layers.toml text.")
			return false
		}
		Result := Deps.Get("apply_nav", _LayMgrWeb_ApplyNav).Call(Payload["text"])
		_LayMgrWeb_PushPayload(Deps, "navResult", Map("saved", LayMgrJsonBool_Of(Result.Get("saved", false)),
			"applied", LayMgrJsonBool_Of(Result.Get("applied", false)), "errors", Result.Get("errors", [])))
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
	if (Action == "composer_open" || Action == "composer_save" || Action == "composer_remove"
			|| Action == "composer_emulate")
		return LayoutComposer_Handle(Action, Payload, Deps)
	Id := Payload.Has("id") ? Payload["id"] : ""
	if !LayoutRegistry_IsValidId(Id) {
		LoggerWarn("LayoutManager", "Refused a layout manager '{1}' without a valid layout id.", Action)
		return false
	}
	State := LayoutManager_PageState(Deps["local_dir"])
	if !_LayMgrWeb_CommandCurrent(SessionEpoch, Action)
		return false
	Entry := LayoutCatalogue_Entry(State["index"], Id)
	if (Action == "open_homepage") {
		Source := (Entry is Map) ? Entry : State["installed"].Get(Id, 0)
		Homepage := (Source is Map) ? Source.Get("homepage", "") : ""
		if !RegExMatch(Homepage, "^https://\S+$") {
			LoggerWarn("LayoutManager", "Refused to open the homepage of '{1}': none is published over https.", Id)
			return false
		}
		if !_LayMgrWeb_CommandCurrent(SessionEpoch, Action)
			return false
		return Deps["open_url"].Call(Homepage)
	}
	if (Action == "install" || Action == "update") {
		if !(Entry is Map) {
			LoggerWarn("LayoutManager", "Refused to {1} '{2}': the catalogue does not list it.", Action, Id)
			return false
		}
		if !_LayMgrWeb_CommandCurrent(SessionEpoch, Action)
			return false
		Deps["install"].Call(Id, _LayMgrWeb_OnDone.Bind(Deps, Id, Action))
		if _LayMgrWeb_CommandCurrent(SessionEpoch, Action)
			_LayMgrWeb_PushState(Deps)
		return true
	}
	if (Action == "select" && State["builtin"].Has(Id)) {
		if !_LayMgrWeb_CommandCurrent(SessionEpoch, Action)
			return false
		Deps["select"].Call(Id)
		return true
	}
	if !State["installed"].Has(Id) {
		LoggerWarn("LayoutManager", "Refused to {1} '{2}': it is not installed.", Action, Id)
		return false
	}
	if (Action == "uninstall") {
		if !_LayMgrWeb_CommandCurrent(SessionEpoch, Action)
			return false
		Outcome := Deps["uninstall"].Call(Id)
		_LayMgrWeb_OnDone(Deps, Id, Action, Outcome["ok"], Outcome.Get("code", ""), Outcome.Get("detail", ""))
		return true
	}
	if !_LayMgrWeb_CommandCurrent(SessionEpoch, Action)
		return false
	Deps["select"].Call(Id)
	return true
}

; Readiness initializes the admitted page under pause; user commands do not.
_LayMgrWeb_CommandCurrent(SessionEpoch, Action) {
	global _LayMgrWeb_SessionEpoch
	return SessionEpoch == _LayMgrWeb_SessionEpoch && (Action == "ready" || !A_IsSuspended)
}

_LayMgrWeb_PresentationCurrent(Deps) {
	global _LayMgrWeb_SessionEpoch
	return Deps.Get("session_epoch", _LayMgrWeb_SessionEpoch) == _LayMgrWeb_SessionEpoch
}

; A result belongs to one page; committing an install remains independent of it.
_LayMgrWeb_PublishResult(Deps, Result) {
	global _LayMgrWeb_Result
	PreviousCritical := Critical("On")
	try {
		if !_LayMgrWeb_PresentationCurrent(Deps)
			return false
		_LayMgrWeb_Result := Result
	} finally Critical(PreviousCritical)
	return true
}

_LayMgrWeb_OnDone(Deps, Id, Action, Ok, CodeOrDetail := "", Detail := "") {
	global _LayMgrWeb_RuntimeRefresh, _LayMgrWeb_SessionEpoch
	; Direct internal callers acquire the same owner as message callbacks.
	if !Deps.Has("session_epoch") {
		Deps := Deps.Clone()
		Deps["session_epoch"] := _LayMgrWeb_SessionEpoch
	}
	if !Ok {
		_LayMgrWeb_PublishResult(Deps, Map("id", Id, "action", Action, "ok", false,
			"code", String(CodeOrDetail), "detail", String(Detail)))
		_LayMgrWeb_PushState(Deps)
		return false
	}
	if !Deps.Has("after") {
		_LayMgrWeb_PublishResult(Deps, Map("id", Id, "action", Action, "ok", true))
		_LayMgrWeb_PushState(Deps)
		return true
	}
	Pending := Map("id", Id, "action", Action)
	_LayMgrWeb_RuntimeRefresh := Pending
	_LayMgrWeb_PublishResult(Deps, 0)
	_LayMgrWeb_PushState(Deps)
	Finish(Ready) {
		global _LayMgrWeb_RuntimeRefresh, _LayMgrWeb_PresentationDeps
		if _LayMgrWeb_RuntimeRefresh != Pending
			return false
		_LayMgrWeb_RuntimeRefresh := 0
		Accepted := (Ready is Integer) && Ready == 1
		Result := Map("id", Id, "action", Action, "ok", Accepted)
		if !Accepted
			Result["code"] := "other"
		_LayMgrWeb_PublishResult(Deps, Result)
		; A replacement page may have observed the operation as busy. Retire
		; that projection with fresh state while preserving its own result.
		if _LayMgrWeb_PresentationCurrent(Deps)
			_LayMgrWeb_PushState(Deps)
		else if _LayMgrWeb_PresentationDeps is Map
			_LayMgrWeb_PushState(_LayMgrWeb_PresentationDeps)
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
	if !_LayMgrWeb_PresentationCurrent(Deps)
		return false
	State := LayoutManager_PageState(Deps["local_dir"])
	if !_LayMgrWeb_PresentationCurrent(Deps)
		return false
	return _LayMgrWeb_PushPayload(Deps, "updateState", State)
}

_LayMgrWeb_PushPayload(Deps, Name, Payload) {
	global _LayMgrWeb_SessionEpoch
	if !_LayMgrWeb_PresentationCurrent(Deps)
		return false
	if Deps["push"] == _LayMgrWeb_Push
		return _LayMgrWeb_Push(Name, Payload, Deps.Get("session_epoch", _LayMgrWeb_SessionEpoch))
	Deps["push"].Call(Name, Payload)
	return true
}

; The configuration folder the editor's files go to: the test's, else the driver's.
_LayMgrWeb_ConfigDir(Deps) {
	global _ConfigDir
	return Deps.Has("config_dir") ? Deps["config_dir"] : _ConfigDir
}

/**
 * The layout editor's strings in the active locale. The macOS and Linux hosts
 * seed window._i18n_strings before the page runs; this host sends them with
 * sourceData, the first message the editor reads.
 * @returns {Map} Every layout_editor.* key -> its translation.
 */
LayoutManager_EditorStrings() {
	global _I18nCache, _I18nCacheEn
	_I18nEnsureLoaded()
	Strings := Map()
	for Cache in [_I18nCache, _I18nCacheEn]
		for Key in Cache
			if SubStr(Key, 1, 14) == "layout_editor." && !Strings.Has(Key)
				Strings[Key] := I18nLookup(Key)
	return Strings
}

; Answers the editor's source_open: the last saved source, else text null.
_LayMgrWeb_SourceOpen(Deps) {
	global JSON_NULL
	Data := SourceStore_Open(SourceStore_SharedSettings(), _LayMgrWeb_ConfigDir(Deps), Deps.Get("source_ports", 0))
	if !Data.Has("text")
		Data["text"] := JSON_NULL, Data["filename"] := JSON_NULL
	Data["strings"] := Deps.Get("editor_strings", LayoutManager_EditorStrings).Call()
	return _LayMgrWeb_PushPayload(Deps, "sourceData", Data)
}

; « Apply the navigation layer »: the navigation layer editor's own save, then
; the pause-preserving reload that applies it.
_LayMgrWeb_ApplyNav(Text) {
	global _SharedDir, _ConfigDir
	return LayerEditor_SaveAndApply(Text, _SharedDir, _ConfigDir, ReloadPreservingSuspend)
}

/**
 * Opens the layout manager straight on the layout editor (the menu's « Create
 * or edit a layout… »): the page receives sourceData as if its « Editor »
 * button had asked, once it is ready.
 * @returns {Boolean} Whether the window is shown.
 */
LayoutManager_OpenEditor(*) {
	global _LayMgrWeb_EditorWanted, _LayMgrWeb_Gui, _LayMgrWeb_ReadyEpoch, _LayMgrWeb_SessionEpoch
	; An open, ready page answers now; a new one answers on its ready.
	Ready := _LayMgrWeb_Gui != 0 && _LayMgrWeb_ReadyEpoch == _LayMgrWeb_SessionEpoch
	_LayMgrWeb_EditorWanted := !Ready
	if !LayoutManager_Open() {
		_LayMgrWeb_EditorWanted := false
		return false
	}
	if Ready
		LayoutManager_HandleMessage(Map("action", "source_open"))
	return true
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
 * Selects a layout and reports its terminal outcome. Launch acceptance only
 * means the successor started: the configuration is rolled back if it later
 * refuses the handoff, so success is reported when the reload commits.
 * @param {String} Id Registry layout identifier.
 * @param {Func} OnDone Called once with (Ok, Detail) at the terminal outcome.
 * @param {Map} Options Configuration lifecycle ports for owner tests.
 * @returns {Boolean} Whether the successor launch was accepted.
 */
LayoutManager_SelectSettled(Id, OnDone, Options := unset) {
	Settled := false
	Settle(Ok, Detail := "") {
		if Settled
			return
		Settled := true
		OnDone.Call(Ok, Detail)
	}
	Lifecycle := IsSet(Options) ? Options.Clone() : Map()
	ReloadFn := Lifecycle.Get("reload", ReloadPreservingSuspend)
	Lifecycle["reload"] := (OnCommitted, Bundle, Refused) => ReloadFn.Call(
		(*) => (OnCommitted.Call(), Settle(true)),
		Bundle,
		(Reason := "") => (Refused.Call(Reason), Settle(false, "the driver refused the layout handoff")))
	Receipt := LayoutManager_SelectTransition(Id, Lifecycle)
	if Receipt["status"] == "committed" {
		Settle(true)
		return true
	}
	if Receipt["status"] == "pending"
		return true
	Settle(false, "the layout could not be selected")
	return false
}

/**
 * Makes a stored layout the emulated one with its base layer on ([layout]
 * emulated_layout and ergopti_base), the « Emulate without installing » of the
 * layout editor, and reports its terminal outcome as LayoutManager_SelectSettled.
 * @param {String} Id Registry layout identifier (the composer's).
 * @param {Func} OnDone Called once with (Ok, Detail) at the terminal outcome.
 * @param {Map} Options Configuration lifecycle ports for owner tests.
 * @returns {Boolean} Whether the successor launch was accepted.
 */
LayoutManager_EmulateSettled(Id, OnDone, Options := unset) {
	Lifecycle := IsSet(Options) ? Options.Clone() : Map()
	Lifecycle["emulate"] := true
	return LayoutManager_SelectSettled(Id, OnDone, Lifecycle)
}

/**
 * Retains the selected configuration until successor completion or rollback.
 * The resident input owner keeps its admitted layout while the reload is pending.
 * @param {String} Id Registry layout identifier.
 * @param {Map} Options Configuration lifecycle ports for owner tests.
 * @returns {Map} Pending or terminal configuration receipt.
 */
LayoutManager_SelectTransition(Id, Options := unset) {
	; "" is the menu's « none »: the system layout types.
	if Id != "" && !LayoutRegistry_IsValidId(Id)
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
		_LayMgrWeb_SelectionOperations.Bind(Id, Path, Expected, SnapshotFn, Options.Get("emulate", false)), Options)
}

; Built-in selections keep the existing empty-emulation contract and overlays.
; A registry selection changes only its source identifier; it owns no layer gate.
; An emulated source also turns its base layer on, which « none » may have left off.
_LayMgrWeb_SelectionOperations(Id, Path, Expected, SnapshotFn, Emulate := false) {
	global ERGOPTI_PLUS_LAYOUT_ID
	Current := SnapshotFn.Call(Path)
	if !(Expected is Map) || !(Current is Map)
			|| !Expected.Get("valid", false) || !Current.Get("valid", false)
			|| Expected.Get("path", "") != Path || Current.Get("path", "") != Path
			|| Expected["presence"] != Current["presence"]
			|| StrCompare(Expected["content"], Current["content"], true) != 0
			|| !ManifestValuesEqual(Expected["values"], Current["values"])
		throw Error("The selected helper source intent changed or could not be admitted.")
	if Id == ""
		return [
			ManifestSparseOperation(ConfigKey.LAYOUT_EMULATED_LAYOUT, ""),
			ManifestSparseOperation(ConfigKey.LAYOUT_ERGOPTI_BASE, false),
			ManifestSparseOperation(ConfigKey.LAYOUT_ERGOPTI_VARIANT, "none"),
		]
	if LayoutManager_BuiltinIds().Has(Id)
		return [
			ManifestSparseOperation(ConfigKey.LAYOUT_EMULATED_LAYOUT, ""),
			ManifestSparseOperation(ConfigKey.LAYOUT_ERGOPTI_BASE, true),
			ManifestSparseOperation(ConfigKey.LAYOUT_ERGOPTI_VARIANT, Id),
		]
	if Emulate
		return [
			ManifestSparseOperation(ConfigKey.LAYOUT_EMULATED_LAYOUT, Id),
			ManifestSparseOperation(ConfigKey.LAYOUT_ERGOPTI_BASE, true),
		]
	return [ManifestSparseOperation(ConfigKey.LAYOUT_EMULATED_LAYOUT, Id)]
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
	; The stored choice is kept (decided on 2026-11-12, as macOS and Linux): the
	; reload stops the emulation, the menu names the layout « cannot be emulated »,
	; and installing it again resumes it. The boot never reinstalls it.
	if Selected && Action == "uninstall"
		LoggerInfo("LayoutManager", "The emulated '{1}' layout was uninstalled; it stays chosen and is no longer emulated.", Id)
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
	_LayMgrWeb_RetryRetiredHosts()
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
	; Native Show can deliver Close before returning. Its original callback
	; must already own this exact window so cancellation can destroy it.
	_LayMgrWeb_Gui := g
	; Shown before the control: a hidden Gui has a zero client rect.
	g.Show("w720 h560 Center")
	if SessionEpoch != _LayMgrWeb_SessionEpoch || _LayMgrWeb_Gui != g {
		try g.Destroy()
		LoggerInfo("LayoutManager", "Layout manager opening cancelled while its window was being shown.")
		return false
	}
	try {
		CreatedController := WebView2.create(Placeholder.Hwnd, , WebView_SharedEnvironment(_VendorDir . "\64bit\WebView2Loader.dll"))
	} catch as Err {
		LoggerError("LayoutManager", "WebView2 create failed: {1}", Err.Message)
		if SessionEpoch == _LayMgrWeb_SessionEpoch && _LayMgrWeb_Gui == g
			_LayMgrWeb_Close()
		return false
	}
	; SDK creation pumps messages while awaiting COM. Claim only the exact GUI
	; before giving its native Close callback custody of this controller.
	PreviousCritical := Critical("On")
	try {
		Admitted := _LayMgrWeb_StartupCurrent(SessionEpoch, g)
		if Admitted
			_LayMgrWeb_Controller := CreatedController
	} finally Critical(PreviousCritical)
	if !Admitted {
		CreatedController.Close()
		LoggerInfo("LayoutManager", "Layout manager opening cancelled after its window was closed or replaced.")
		return false
	}
	Controller := CreatedController
	View := Controller.CoreWebView2
	; A Close during the property getter already retired the published controller.
	; The abandoned frame must neither close it twice nor publish over a successor.
	PreviousCritical := Critical("On")
	try {
		Admitted := _LayMgrWeb_StartupCurrent(SessionEpoch, g, Controller)
		if Admitted
			_LayMgrWeb_WebView := View
	} finally Critical(PreviousCritical)
	if !Admitted
		return false
	try {
		s := View.Settings
		if !_LayMgrWeb_StartupCurrent(SessionEpoch, g, Controller, View)
			return false
		s.AreDevToolsEnabled := false
		if !_LayMgrWeb_StartupCurrent(SessionEpoch, g, Controller, View)
			return false
		s.AreDefaultContextMenusEnabled := false
		if !_LayMgrWeb_StartupCurrent(SessionEpoch, g, Controller, View)
			return false
		s.IsStatusBarEnabled := false
		if !_LayMgrWeb_StartupCurrent(SessionEpoch, g, Controller, View)
			return false
		s.AreBrowserAcceleratorKeysEnabled := false
		if !_LayMgrWeb_StartupCurrent(SessionEpoch, g, Controller, View)
			return false
		s.IsSwipeNavigationEnabled := false
	}
	; Optional settings may throw as before; cancellation is still terminal.
	if !_LayMgrWeb_StartupCurrent(SessionEpoch, g, Controller, View)
		return false
	Host := _LayMgrWeb_BeginSubscriptions(SessionEpoch, g, Controller, View)
	if !IsObject(Host)
		return false
	if !_LayMgrWeb_Subscribe(Host, "message", _LayMgrWeb_OnWebMessage.Bind(SessionEpoch))
		return false
	if !_LayMgrWeb_Subscribe(Host, "navigation", _LayMgrWeb_OnNavigationCompleted.Bind(SessionEpoch))
		return false
	View.SetVirtualHostNameToFolderMapping(LAYMGR_VHOST, _SharedDir, LAYMGR_HOST_ACCESS_ALLOW)
	if !_LayMgrWeb_StartupCurrent(SessionEpoch, g, Controller, View)
		return false
	View.Navigate("https://" . LAYMGR_VHOST . "/ui/layout_manager/index.html?cb=" . A_TickCount)
	if !_LayMgrWeb_StartupCurrent(SessionEpoch, g, Controller, View)
		return false
	Controller.Fill()
	if !_LayMgrWeb_StartupCurrent(SessionEpoch, g, Controller, View)
		return false
	LoggerSuccess("LayoutManager", "Layout manager opened.")
	return _LayMgrWeb_StartupCurrent(SessionEpoch, g, Controller, View)
}


; RAM-only admission for a partially configured native host. Browser calls stay
; outside Critical, and a returned old frame never adopts current globals.
_LayMgrWeb_StartupCurrent(SessionEpoch, Window, Controller := 0, View := 0) {
	global _LayMgrWeb_SessionEpoch, _LayMgrWeb_Gui, _LayMgrWeb_ResetDone
	global _LayMgrWeb_Controller, _LayMgrWeb_WebView
	if SessionEpoch != _LayMgrWeb_SessionEpoch || _LayMgrWeb_Gui != Window || _LayMgrWeb_ResetDone
		return false
	if IsObject(Controller) && (!IsSet(_LayMgrWeb_Controller) || _LayMgrWeb_Controller != Controller)
		return false
	return !IsObject(View) || (IsSet(_LayMgrWeb_WebView) && _LayMgrWeb_WebView == View)
}


_LayMgrWeb_BeginSubscriptions(Epoch, Window, Controller, View) {
	global _LayMgrWeb_SubscriptionOwner
	Host := {epoch: Epoch, gui: Window, controller: Controller, view: View,
		message: 0, navigation: 0, in_flight: false, retired: false, closing: false, closed: false}
	PreviousCritical := Critical("On")
	try {
		if !_LayMgrWeb_StartupCurrent(Epoch, Window, Controller, View) || IsObject(_LayMgrWeb_SubscriptionOwner)
			return 0
		_LayMgrWeb_SubscriptionOwner := Host
		return Host
	} finally Critical(PreviousCritical)
}

; The SDK creates its unsubscribe handle after add_Event returns. Native Close
; can retire the GUI while that call pumps, but cannot close its controller yet.
_LayMgrWeb_Subscribe(Host, Kind, Handler) {
	global _LayMgrWeb_SubscriptionOwner, _LayMgrWeb_MsgSub, _LayMgrWeb_NavSub
	PreviousCritical := Critical("On")
	try {
		if Host.retired || _LayMgrWeb_SubscriptionOwner != Host
				|| !_LayMgrWeb_StartupCurrent(Host.epoch, Host.gui, Host.controller, Host.view)
			return false
		Host.in_flight := true
	} finally Critical(PreviousCritical)
	Subscription := 0, Failed := false, FailureType := ""
	try {
		Subscription := Kind == "message" ? Host.view.WebMessageReceived(Handler)
			: Host.view.NavigationCompleted(Handler)
	} catch Any as Failure {
		Failed := true, FailureType := Type(Failure)
	} finally {
		PreviousCritical := Critical("On")
		try {
			Host.%Kind% := Subscription
			; Host retains the handle before this alias disappears; clearing the
			; alias cannot invoke its destructor inside the short RAM claim.
			Subscription := 0
			Host.in_flight := false
			Current := !Host.retired && _LayMgrWeb_SubscriptionOwner == Host
				&& _LayMgrWeb_StartupCurrent(Host.epoch, Host.gui, Host.controller, Host.view)
			if Current && !Failed {
				if Kind == "message"
					_LayMgrWeb_MsgSub := Host.message
				else
					_LayMgrWeb_NavSub := Host.navigation
			}
		} finally Critical(PreviousCritical)
	}
	if Failed && Current
		_LayMgrWeb_Reset(Host)
	if Host.retired
		_LayMgrWeb_RetryRetiredHosts()
	if Failed
		try LoggerError("LayoutManager", "Browser subscription failed (error_type={1}).", FailureType)
	return !Failed && Current && !Host.retired
}

_LayMgrWeb_QueueRetiredHost(Host) {
	global _LayMgrWeb_RetiredHosts
	PreviousCritical := Critical("On")
	try {
		for Pending in _LayMgrWeb_RetiredHosts
			if Pending == Host
				return
		_LayMgrWeb_RetiredHosts.Push(Host)
	} finally Critical(PreviousCritical)
}

; Close refusals retain the exact controller and HWND, never a pathname-like
; lookup of the current singleton. A successor can be opened independently.
_LayMgrWeb_RetryRetiredHosts() {
	global _LayMgrWeb_RetiredHosts
	PreviousCritical := Critical("On")
	try Pending := _LayMgrWeb_RetiredHosts.Clone()
	finally Critical(PreviousCritical)
	for Host in Pending {
		PreviousCritical := Critical("On")
		try {
			if Host.in_flight || Host.closing
				continue
			Host.closing := true
		} finally Critical(PreviousCritical)
		Settled := false
		try {
			; No local alias may keep either SDK handle beyond controller Close.
			Host.message := 0
			Host.navigation := 0
			if !Host.closed && IsObject(Host.controller) {
				Host.controller.Close()
				Host.closed := true
			}
			if IsObject(Host.gui)
				Host.gui.Destroy()
			Host.gui := 0, Host.controller := 0, Host.view := 0
			Settled := true
		} catch Any as Failure {
			try LoggerWarn("LayoutManager", "Native layout host retirement remains pending (error_type={1}).", Type(Failure))
		} finally {
			PreviousCritical := Critical("On")
			try {
				Host.closing := false
				if Settled {
					Count := _LayMgrWeb_RetiredHosts.Length
					Loop Count {
						Index := Count - A_Index + 1
						if _LayMgrWeb_RetiredHosts[Index] == Host
							_LayMgrWeb_RetiredHosts.RemoveAt(Index)
					}
				}
			} finally Critical(PreviousCritical)
		}
	}
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
	; Preserve the scheduling epoch across dependency reads and page snapshots.
	if Callback == LayoutManager_HandleMessage && Params.Length > 0 {
		if Params.Length == 1
			Params.Push(0)
		Params.Push(SessionEpoch)
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
_LayMgrWeb_Push(FunctionName, Payload, ExpectedEpoch := unset) {
	global _LayMgrWeb_WebView, _LayMgrWeb_SessionEpoch
	if !IsSet(ExpectedEpoch)
		ExpectedEpoch := _LayMgrWeb_SessionEpoch
	if ExpectedEpoch != _LayMgrWeb_SessionEpoch || !IsSet(_LayMgrWeb_WebView)
		return false
	View := _LayMgrWeb_WebView, Epoch := ExpectedEpoch
	Script := "if(window." . FunctionName . ")window." . FunctionName . "(" . _LayMgrWeb_Json(Payload) . ")"
	if Epoch != _LayMgrWeb_SessionEpoch || !IsSet(_LayMgrWeb_WebView) || View != _LayMgrWeb_WebView
		return false
	WebView_RunScriptAsync(View, Script, "LayoutManager")
	return true
}

_LayMgrWeb_OnResize(GuiObj, MinMax, Width, Height) {
	global _LayMgrWeb_Controller
	if (MinMax == -1)
		return
	if IsSet(_LayMgrWeb_Controller)
		try WebView_FitToWindow(_LayMgrWeb_Controller)
}

_LayMgrWeb_Close(Params*) {
	Window := Params.Length && Params[1] is Gui ? Params[1] : 0
	_LayMgrWeb_Reset(0, Window)
}

; Retire the exact logical host before unsubscribe, Close, Hide or Destroy can
; deliver another public opening. A pending add_Event keeps its HWND alive.
_LayMgrWeb_Reset(ExpectedHost := 0, ExpectedWindow := 0) {
	global _LayMgrWeb_Gui, _LayMgrWeb_Controller, _LayMgrWeb_WebView, _LayMgrWeb_MsgSub, _LayMgrWeb_NavSub
	global _LayMgrWeb_ResetDone, _LayMgrWeb_SessionEpoch, _LayMgrWeb_PresentationDeps, _LayMgrWeb_SubscriptionOwner
	PreviousCritical := Critical("On")
	try {
		if _LayMgrWeb_ResetDone
			return
		if IsObject(ExpectedWindow) && _LayMgrWeb_Gui != ExpectedWindow
			return
		if IsObject(ExpectedHost) && (_LayMgrWeb_SubscriptionOwner != ExpectedHost
				|| !_LayMgrWeb_StartupCurrent(ExpectedHost.epoch, ExpectedHost.gui, ExpectedHost.controller, ExpectedHost.view))
			return
		Host := IsObject(_LayMgrWeb_SubscriptionOwner) ? _LayMgrWeb_SubscriptionOwner
			: {epoch: _LayMgrWeb_SessionEpoch, gui: _LayMgrWeb_Gui, controller: 0, view: 0,
				message: 0, navigation: 0, in_flight: false, retired: false, closing: false, closed: false}
		if IsSet(_LayMgrWeb_Controller)
			Host.controller := _LayMgrWeb_Controller
		if IsSet(_LayMgrWeb_WebView)
			Host.view := _LayMgrWeb_WebView
		if IsSet(_LayMgrWeb_MsgSub)
			Host.message := _LayMgrWeb_MsgSub
		if IsSet(_LayMgrWeb_NavSub)
			Host.navigation := _LayMgrWeb_NavSub
		Presentation := _LayMgrWeb_PresentationDeps
		Host.retired := true
		_LayMgrWeb_ResetDone := true
		_LayMgrWeb_SessionEpoch += 1
		_LayMgrWeb_Gui := 0, _LayMgrWeb_SubscriptionOwner := 0, _LayMgrWeb_PresentationDeps := 0
		_LayMgrWeb_Controller := unset, _LayMgrWeb_WebView := unset
		_LayMgrWeb_MsgSub := unset, _LayMgrWeb_NavSub := unset
	} finally Critical(PreviousCritical)
	_LayMgrWeb_QueueRetiredHost(Host)
	if IsObject(Host.gui)
		try Host.gui.Hide()
	_LayMgrWeb_RetryRetiredHosts()
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
		for Field in [ConfigKey.LAYOUT_ERGOPTI_VARIANT, ConfigKey.LAYOUT_EMULATED_LAYOUT, ConfigKey.LAYOUT_ERGOPTI_BASE,
			ConfigKey.LAYOUT_ERGOPTI_ALT_GR, "category_enabled.layout"] {
			Read := _TOML_DocumentLookup(Document, StrSplit(Field, "."))
			if Read["blocked"]
				return Snapshot
			Value := Read["found"] ? Read["value"] : ManifestDefaultFor(Field)
			if Field == ConfigKey.LAYOUT_ERGOPTI_BASE || Field == ConfigKey.LAYOUT_ERGOPTI_ALT_GR || Field == "category_enabled.layout" {
				if Read["found"] && !(Value is TOML_Bool)
					return Snapshot
				if Value is TOML_Bool
					Value := Value.Value
			} else if Field == ConfigKey.LAYOUT_ERGOPTI_VARIANT {
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
